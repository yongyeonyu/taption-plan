import SwiftUI

/// 오른쪽 위 날짜 배지를 눌러 펼치는 날짜 줄.
///
/// 선택일 앞뒤 120일을 가로 스크롤로 둘러본다. 손가락을 끊김 없이 따라가고 관성도 있으며, 손을 뗄 때만
/// 가장 가까운 칸에 스냅한다(대표 지시, ARC1030A02). 밀어도 선택일은 그대로이고 칸을 탭해야 날짜가 바뀐다.
struct MapHomeDateStrip: View {
    let language: MapHomeLanguage
    let selectedDate: Date
    /// 날짜 칸을 눌렀거나 쓸어 넘겨 날짜가 바뀌었을 때. 부모가 선택일을 바꾼다.
    let onSelect: (Date) -> Void

    /// 줄 가운데에 와 있는 날짜(날짜 id). 밀면 계속 바뀌지만 선택한 날짜는 바뀌지 않는다. 날짜 칸을 탭해야 그날로 이동한다(대표 지시, ARC1030A02).
    @State private var centeredDay: Date?

    private var calendar: Calendar { TimelineAxisGrid.normalizedCalendar() }

    var body: some View {
        // 시스템 가로 스크롤이라 손가락을 끊김 없이 따라가고 관성도 있다. 손을 뗄 때만 가장 가까운 칸에 스냅한다.
        let days = MapHomeWeekStripMath.window(
            around: selectedDate, calendar: calendar, radius: MapHomeWeekStripMath.scrollWindowRadius
        )
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: MapHomeWeekStripMath.daySpacing) {
                ForEach(days, id: \.self) { day in
                    dayCell(day)
                }
            }
            .scrollTargetLayout()
        }
        .contentMargins(.horizontal, (MapHomeWeekStripMath.visibleWidth - MapHomeWeekStripMath.dayWidth) / 2, for: .scrollContent)
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: $centeredDay, anchor: .center)
        .frame(width: MapHomeWeekStripMath.visibleWidth)
        .padding(.horizontal, 6)
        .frame(height: MapHomeWeekStripMath.height)
        .onAppear { centeredDay = calendar.startOfDay(for: selectedDate) }
        .onChange(of: selectedDate) { _, date in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                centeredDay = calendar.startOfDay(for: date)
            }
        }
        .mapHomeGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        // 화면 시험에서 이 줄을 이름으로 집는다. 자식(날짜 칸)은 그대로 눌린다.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mapHomeDateWeekStrip")
    }

    private func dayCell(_ day: Date) -> some View {
        let weekday = calendar.component(.weekday, from: day)
        let isHoliday = MapHomeCalendarDayStyle(date: day, calendar: calendar) == .holiday
        let tint: Color = isHoliday || weekday == 1
            ? .tpHoliday
            : (weekday == 7 ? .tpReferenceBlue : .tpInk)
        let isSelected = calendar.isDate(day, inSameDayAs: selectedDate)
        return Button {
            // 날짜 줄은 오른쪽 위 날짜 배지를 눌러서만 닫는다. 날짜 칸을 누르면 날짜만 바뀐다.
            onSelect(day)
        } label: {
            VStack(spacing: 0) {
                Text(day.formatted(
                    Date.FormatStyle()
                        .weekday(.narrow)
                        .locale(Locale(identifier: language.text("ko_KR", "en_US")))
                ))
                .font(.system(size: TaptionType.scaled(TaptionType.snapped(10)), weight: .semibold, design: .rounded))
                .foregroundStyle(tint)
                Text(String(calendar.component(.day, from: day)))
                    .font(.system(size: TaptionType.scaled(TaptionType.snapped(16)), weight: .bold, design: .rounded))
                    .foregroundStyle(Color.tpInk)
                    .monospacedDigit()
            }
            .frame(width: MapHomeWeekStripMath.dayWidth, height: MapHomeWeekStripMath.height - 8)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.tpReferenceBlue.opacity(0.22))
                }
            }
        }
        .buttonStyle(.plain)
    }
}

enum MapHomeWeekStripMath {
    /// 날짜 한 칸의 너비.
    static let dayWidth: CGFloat = 34
    /// 날짜 칸 사이 간격.
    static let daySpacing: CGFloat = 4
    /// 날짜 한 칸이 차지하는 폭(칸 34pt + 간격 4pt).
    static let dayPitch: CGFloat = dayWidth + daySpacing
    /// 날짜 줄 높이. 양옆 원형 버튼과 같은 높이(40pt).
    static let height: CGFloat = 40
    /// 날짜 줄에 한 번에 보이는 날 수. 홀수라야 선택일이 가운데 온다.
    static let visibleDays = 7
    /// 선택일 앞뒤로 보여 줄 날 수(창 반폭).
    static let windowRadius = visibleDays / 2

    /// 선택일을 가운데 두고 앞뒤로 같은 수의 날을 만든다.
    ///
    /// 달력 주(일~토)를 그대로 그리면 선택일이 줄의 가장자리에 걸려
    /// '여기서 더 못 간다'처럼 보인다. 창을 선택일에 붙여 두면 하루 넘길
    /// 때마다 새 날짜가 좌우에서 계속 들어온다.
    /// 스크롤로 둘러볼 수 있는 선택일 앞뒤 날 수.
    static let scrollWindowRadius = 120
    /// 보이는 7칸의 폭.
    static let visibleWidth: CGFloat = CGFloat(visibleDays) * dayWidth + CGFloat(visibleDays - 1) * daySpacing

    static func window(around date: Date, calendar: Calendar, radius: Int = windowRadius) -> [Date] {
        let base = calendar.startOfDay(for: date)
        return (-radius...radius).compactMap {
            calendar.date(byAdding: .day, value: $0, to: base)
        }
    }
}
