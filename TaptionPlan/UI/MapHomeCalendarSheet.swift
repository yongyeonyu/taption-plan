import SwiftUI

/// A compact month selector used by the map home header.
///
/// The sheet deliberately owns only calendar presentation. Holiday dates are
/// supplied by the caller so the same verified holiday source can be reused by
/// the timeline and other date pickers.
struct MapHomeCalendarSheet: View {
    @Binding private var selectedDate: Date
    private let holidayName: (Date) -> String?
    private let calendar: Calendar

    @State private var displayedMonth: Date

    init(
        selectedDate: Binding<Date>,
        holidayName: @escaping (Date) -> String?
    ) {
        self._selectedDate = selectedDate
        self.holidayName = holidayName

        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "ko_KR")
        calendar.timeZone = .current
        calendar.firstWeekday = 1
        self.calendar = calendar

        let day = calendar.startOfDay(for: selectedDate.wrappedValue)
        self._displayedMonth = State(initialValue: calendar.date(
            from: calendar.dateComponents([.year, .month], from: day)
        ) ?? day)
    }

    var body: some View {
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
                .padding(.bottom, 18)
        }
        .frame(maxWidth: 390)
        .background(Color.white)
        .presentationDetents([.height(410)])
        .presentationDragIndicator(.visible)
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
            .accessibilityLabel("이전 달")

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
            .accessibilityLabel("다음 달")
        }
    }

    private var weekdayHeader: some View {
        let weekdays = ["일", "월", "화", "수", "목", "금", "토"]
        return LazyVGrid(columns: gridColumns, spacing: 0) {
            ForEach(Array(weekdays.enumerated()), id: \.offset) { index, weekday in
                Text(weekday)
                    .font(.system(size: index == 6 ? 10 : 12, weight: .semibold))
                    .foregroundStyle(weekdayColor(index: index))
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

                Circle()
                    .fill(holiday == nil ? Color.clear : Color.tpHoliday)
                    .frame(width: 3, height: 3)
            }
            .frame(maxWidth: .infinity, minHeight: 38)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel(day: day, date: date, holiday: holiday))
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
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.calendar = calendar
        formatter.dateFormat = "yyyy년 M월"
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

    private func dayColor(weekday: Int, holiday: String?) -> Color {
        if holiday != nil || weekday == 1 { return .tpHoliday }
        if weekday == 7 { return .tpSaturday }
        return .tpInk
    }

    private func accessibilityLabel(day: Int, date: Date, holiday: String?) -> String {
        let title = "\(monthTitle) \(day)일"
        return holiday.map { "\(title), \($0)" } ?? title
    }
}
