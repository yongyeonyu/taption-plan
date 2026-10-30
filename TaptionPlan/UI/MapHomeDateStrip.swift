import SwiftUI

/// 오른쪽 위 날짜 배지를 눌러 펼치는 날짜 줄.
///
/// 선택일 앞뒤 날짜를 고정 간격으로 놓고, 손가락 이동만큼 옮긴다. 밀면 가운데 날짜만 바뀌고
/// 선택일은 그대로이며, 칸을 탭해야 날짜가 바뀐다(대표 지시, ARC1030A02).
/// 스크롤 뷰 대신 칸 위치를 직접 계산해 칸이 겹쳐 보이거나 배경이 어긋나지 않게 한다.
struct MapHomeDateStrip: View {
    let language: MapHomeLanguage
    let selectedDate: Date
    /// 날짜 칸을 눌렀을 때. 부모가 선택일을 바꾼다.
    let onSelect: (Date) -> Void

    /// 줄 가운데에 와 있는 날짜. 밀면 바뀌지만 선택일은 바뀌지 않는다.
    @State private var centeredDay: Date?
    /// 손가락을 따라가는 중의 가로 이동량. 손을 떼면 칸 한 개 단위로 스냅한다.
    @State private var dragOffset: CGFloat = 0

    private var calendar: Calendar { TimelineAxisGrid.normalizedCalendar() }

    var body: some View {
        GeometryReader { proxy in
            strip(width: proxy.size.width)
        }
        .frame(height: MapHomeWeekStripMath.height)
        .onAppear { centeredDay = calendar.startOfDay(for: selectedDate) }
        .onChange(of: selectedDate) { _, date in
            // 선택일이 바뀌면 그 날을 가운데에 둔다. 애니메이션 없이 바로 맞춘다.
            centeredDay = calendar.startOfDay(for: date)
            dragOffset = 0
        }
        // 화면 시험에서 이 줄을 이름으로 집는다. 자식(날짜 칸)은 그대로 눌린다.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mapHomeDateWeekStrip")
    }

    private func strip(width: CGFloat) -> some View {
        let dayAreaWidth = width - MapHomeWeekStripMath.monthLabelWidth
        return HStack(spacing: 0) {
            monthLabel
                .frame(width: MapHomeWeekStripMath.monthLabelWidth)
            dayArea(width: dayAreaWidth)
        }
        .frame(width: width, height: MapHomeWeekStripMath.height)
        .mapHomeGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    /// 펼친 줄의 맨 왼쪽에 보이는 선택 날짜의 달. 어느 달인지 헷갈리지 않게 한다.
    private var monthLabel: some View {
        let month = calendar.component(.month, from: selectedDate)
        return Text(language.text("\(month)월", monthAbbreviation))
            .font(.system(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .bold, design: .rounded))
            .foregroundStyle(Color.tpInk)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .accessibilityIdentifier("mapHomeDateStripMonth")
    }

    private var monthAbbreviation: String {
        selectedDate.formatted(Date.FormatStyle().month(.abbreviated).locale(Locale(identifier: "en_US")))
    }

    /// 칸은 가운데 날짜를 기준으로 고정 간격에 놓는다. 화면 밖 칸은 그리지 않는다.
    private func dayArea(width: CGFloat) -> some View {
        let pitch = MapHomeWeekStripMath.dayPitch
        let center = centeredDay ?? calendar.startOfDay(for: selectedDate)
        let reach = Int((width / 2 / pitch).rounded(.up)) + 1
        return ZStack {
            ForEach(-reach...reach, id: \.self) { step in
                if let day = calendar.date(byAdding: .day, value: step, to: center) {
                    dayCell(day)
                        .position(
                            x: width / 2 + CGFloat(step) * pitch + dragOffset,
                            y: MapHomeWeekStripMath.height / 2
                        )
                }
            }
        }
        .frame(width: width, height: MapHomeWeekStripMath.height)
        .clipped()
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 6)
                .onChanged { value in
                    dragOffset = value.translation.width
                }
                .onEnded { value in
                    let flick = value.predictedEndTranslation.width
                    let steps = -Int((flick / pitch).rounded())
                    let next = calendar.date(byAdding: .day, value: steps, to: center) ?? center
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
                        centeredDay = next
                        dragOffset = 0
                    }
                }
        )
    }

    private func dayCell(_ day: Date) -> some View {
        let weekday = calendar.component(.weekday, from: day)
        let isHoliday = MapHomeCalendarDayStyle(date: day, calendar: calendar) == .holiday
        let tint: Color = isHoliday || weekday == 1
            ? .tpHoliday
            : (weekday == 7 ? .tpReferenceBlue : .tpInk)
        let isSelected = calendar.isDate(day, inSameDayAs: selectedDate)
        return Button {
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
    /// 날짜 줄에 한 번에 보이는 날 수 기준. 홀수라야 선택일이 가운데 온다.
    static let visibleDays = 7
    /// 줄 맨 왼쪽의 달 표시 칸 너비.
    static let monthLabelWidth: CGFloat = 36
    /// 선택일 앞뒤로 보여 줄 날 수(창 반폭).
    static let windowRadius = visibleDays / 2
    /// 보이는 7칸의 폭.
    static let visibleWidth: CGFloat = CGFloat(visibleDays) * dayWidth + CGFloat(visibleDays - 1) * daySpacing

    static func window(around date: Date, calendar: Calendar, radius: Int = windowRadius) -> [Date] {
        let base = calendar.startOfDay(for: date)
        return (-radius...radius).compactMap {
            calendar.date(byAdding: .day, value: $0, to: base)
        }
    }
}
