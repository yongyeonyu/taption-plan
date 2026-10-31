import SwiftUI

/// 오른쪽 위 날짜 배지를 눌러 펼치는 날짜 줄.
///
/// 칸은 가운데 날짜를 기준으로 고정 간격에 놓고, 손가락 이동만큼 옮긴다. 가운데 오는 칸을 강조하고,
/// 손을 떼면 가까운 칸으로 스냅한다. 날짜는 손을 뗀 순간 먼저 고르고, 그날 데이터는 부모가 그다음에 불러온다.
/// 칸 목록(요일·공휴일 색)은 가운데 날짜가 바뀔 때만 다시 만들어 끌 때 계산을 줄인다.
struct MapHomeDateStrip: View {
    let language: MapHomeLanguage
    let selectedDate: Date
    /// 데이터가 있는 날(하루의 시작 시각). 칸 아래에 점으로 표시한다.
    let markedDays: Set<Date>
    /// 날짜가 정해졌을 때. 부모가 선택일을 바꾸고 그날 데이터를 불러온다.
    let onSelect: (Date) -> Void

    /// 칸 목록을 만드는 반경(날 수). 줄 너비보다 넉넉하게 잡아 창 크기가 바뀌어도 칸이 모자라지 않게 한다.
    private static let cellRadius = 10

    private let calendar = TimelineAxisGrid.normalizedCalendar()
    /// 줄 가운데에 와 있는 날짜. 밀면 바뀌지만 선택일은 손을 뗄 때까지 그대로다.
    @State private var centeredDay: Date?
    /// 가운데 날짜 기준으로 만든 칸 목록. 끌 때는 이 목록의 위치만 바꾼다.
    @State private var cells: [StripDay] = []
    /// 손가락을 따라가는 중의 가로 이동량.
    @State private var dragOffset: CGFloat = 0

    private struct StripDay: Identifiable {
        let step: Int
        let date: Date
        let number: String
        let weekday: String
        let tint: Color
        var id: Int { step }
    }

    /// 손가락 이동으로 지금 가운데 와 있는 칸이 기준 날짜에서 몇 칸 옮겨졌는지.
    private var dragShift: Int {
        Int((-dragOffset / MapHomeWeekStripMath.dayPitch).rounded())
    }

    /// 지금 화면 가운데 보이는 날짜. 달 표시와 강조가 여기를 따른다.
    private var visibleDay: Date {
        let base = centeredDay ?? calendar.startOfDay(for: selectedDate)
        return calendar.date(byAdding: .day, value: dragShift, to: base) ?? base
    }

    var body: some View {
        GeometryReader { proxy in
            strip(width: proxy.size.width)
        }
        .frame(height: MapHomeWeekStripMath.height)
        .onAppear { recenter(on: selectedDate) }
        .onChange(of: selectedDate) { _, date in
            // 선택일이 바뀌면 그 날을 가운데에 둔다. 애니메이션 없이 바로 맞춘다.
            dragOffset = 0
            recenter(on: date)
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

    /// 펼친 줄의 맨 왼쪽에 보이는 가운데 날짜의 달. 어느 달인지 헷갈리지 않게 한다.
    private var monthLabel: some View {
        let month = calendar.component(.month, from: visibleDay)
        return Text(language.text("\(month)월", monthAbbreviation(for: visibleDay)))
            .font(.system(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .bold, design: .rounded))
            .foregroundStyle(Color.tpInk)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .accessibilityIdentifier("mapHomeDateStripMonth")
    }

    private func monthAbbreviation(for date: Date) -> String {
        date.formatted(Date.FormatStyle().month(.abbreviated).locale(Locale(identifier: "en_US")))
    }

    /// 화면 안에 걸친 칸만 놓는다. 위치는 가운데 날짜 기준 간격과 손가락 이동량으로 정한다.
    private func dayArea(width: CGFloat) -> some View {
        let pitch = MapHomeWeekStripMath.dayPitch
        let shift = dragShift
        return ZStack {
            ForEach(cells) { day in
                let x = width / 2 + CGFloat(day.step) * pitch + dragOffset
                if abs(x - width / 2) <= width / 2 + pitch {
                    dayCell(day, isCentered: day.step == shift)
                        .position(x: x, y: MapHomeWeekStripMath.height / 2)
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
                    let base = centeredDay ?? calendar.startOfDay(for: selectedDate)
                    let next = calendar.date(byAdding: .day, value: steps, to: base) ?? base
                    // 자석처럼 가까운 칸에 붙인다. 날짜는 같은 순간 고르고, 데이터는 부모가 그다음에 불러온다.
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        centeredDay = next
                        dragOffset = 0
                    }
                    cells = makeCells(around: next)
                    Task { @MainActor in onSelect(next) }
                }
        )
    }

    /// 가운데 날짜가 정해졌을 때 한 번만 칸 목록을 만든다.
    private func recenter(on date: Date) {
        let center = calendar.startOfDay(for: date)
        centeredDay = center
        cells = makeCells(around: center)
    }

    private func makeCells(around center: Date) -> [StripDay] {
        (-Self.cellRadius...Self.cellRadius).compactMap { step in
            guard let day = calendar.date(byAdding: .day, value: step, to: center) else { return nil }
            let weekday = calendar.component(.weekday, from: day)
            let isHoliday = MapHomeCalendarDayStyle(date: day, calendar: calendar) == .holiday
            let tint: Color = isHoliday || weekday == 1
                ? .tpHoliday
                : (weekday == 7 ? .tpReferenceBlue : .tpInk)
            return StripDay(
                step: step,
                date: day,
                number: String(calendar.component(.day, from: day)),
                weekday: day.formatted(
                    Date.FormatStyle()
                        .weekday(.narrow)
                        .locale(Locale(identifier: language.text("ko_KR", "en_US")))
                ),
                tint: tint
            )
        }
    }

    /// 가운데 오는 날짜 칸을 파랗게 강조한다. 밀면 강조도 같이 옮겨 간다.
    private func dayCell(_ day: StripDay, isCentered: Bool) -> some View {
        Button {
            onSelect(day.date)
        } label: {
            VStack(spacing: 0) {
                Text(day.weekday)
                    .font(.system(size: TaptionType.scaled(TaptionType.snapped(10)), weight: .semibold, design: .rounded))
                    .foregroundStyle(day.tint)
                Text(day.number)
                    .font(.system(size: TaptionType.scaled(TaptionType.snapped(16)), weight: .bold, design: .rounded))
                    .foregroundStyle(Color.tpInk)
                    .monospacedDigit()
            }
            .frame(width: MapHomeWeekStripMath.dayWidth, height: MapHomeWeekStripMath.height - 8)
            .background {
                if isCentered {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.tpReferenceBlue.opacity(0.22))
                }
            }
            .overlay(alignment: .bottom) {
                if markedDays.contains(day.date) {
                    Circle()
                        .fill(Color.tpReferenceBlue)
                        .frame(width: 4, height: 4)
                        .padding(.bottom, 1)
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
