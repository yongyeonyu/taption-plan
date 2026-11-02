import SwiftUI

/// 오른쪽 위 날짜 배지를 눌러 펼치는 날짜 줄.
///
/// 시스템 스크롤 위에 올려 손가락을 끊김 없이 따라가고 관성으로 이어지며, 손을 떼면 가까운 날짜 칸에
/// 자석처럼 붙는다. 날짜는 스크롤이 멈춘 뒤 한 번만 고른다(그날 데이터를 불러오면 스크롤이 끊긴다).
struct MapHomeDateStrip: View {
    let language: MapHomeLanguage
    let selectedDate: Date
    /// 데이터가 있는 날(하루의 시작 시각). 칸 아래에 점으로 표시한다.
    let markedDays: Set<Date>
    /// 날짜가 정해졌을 때. 부모가 선택일을 바꾸고 그날 데이터를 불러온다.
    let onSelect: (Date) -> Void

    /// 기준 날짜 앞뒤로 스크롤할 수 있는 날 수. 끝에 가까워지면 기준을 옮긴다.
    private static let scrollRadius = 400

    private let calendar = TimelineAxisGrid.normalizedCalendar()
    /// 칸 번호 0에 해당하는 날짜.
    @State private var anchorDay: Date?
    /// 줄 가운데에 와 있는 칸 번호. 밀면 바뀌지만 선택일은 스크롤이 멈출 때까지 그대로다.
    @State private var centeredStep: Int?

    private var baseDay: Date { anchorDay ?? calendar.startOfDay(for: selectedDate) }

    private func date(forStep step: Int) -> Date {
        calendar.date(byAdding: .day, value: step, to: baseDay) ?? baseDay
    }

    /// 지금 화면 가운데 보이는 날짜. 달 표시와 강조가 여기를 따른다.
    private var visibleDay: Date { date(forStep: centeredStep ?? 0) }

    var body: some View {
        GeometryReader { proxy in
            strip(width: proxy.size.width)
        }
        .frame(height: MapHomeWeekStripMath.height)
        .onAppear { recenter(on: selectedDate) }
        .onChange(of: selectedDate) { _, date in
            // 선택일이 바뀌면 그 날을 가운데에 둔다. 스크롤이 멈춰 고른 날이면 이미 가운데라 그대로다.
            guard calendar.startOfDay(for: date) != visibleDay else { return }
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
            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .bold))
            .foregroundStyle(Color.tpInk)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .accessibilityIdentifier("mapHomeDateStripMonth")
    }

    private func monthAbbreviation(for date: Date) -> String {
        date.formatted(Date.FormatStyle().month(.abbreviated).locale(Locale(identifier: "en_US")))
    }

    private func dayArea(width: CGFloat) -> some View {
        let pitch = MapHomeWeekStripMath.dayPitch
        return ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 0) {
                ForEach(-Self.scrollRadius...Self.scrollRadius, id: \.self) { step in
                    dayCell(step: step, isCentered: step == (centeredStep ?? 0))
                        .frame(width: pitch, height: MapHomeWeekStripMath.height)
                        .id(step)
                }
            }
            .scrollTargetLayout()
        }
        .contentMargins(.horizontal, max(0, (width - pitch) / 2), for: .scrollContent)
        .scrollTargetBehavior(.viewAligned(limitBehavior: .never))
        .scrollPosition(id: $centeredStep, anchor: .center)
        .onScrollPhaseChange { _, phase in
            guard phase == .idle else { return }
            settle()
        }
        .frame(width: width, height: MapHomeWeekStripMath.height)
    }

    /// 스크롤이 멈추면 가운데 날짜를 고른다. 끝에 가까우면 기준을 옮겨 계속 밀 수 있게 한다.
    private func settle() {
        let day = visibleDay
        if abs(centeredStep ?? 0) > Self.scrollRadius - 30 { recenter(on: day) }
        if day != calendar.startOfDay(for: selectedDate) { onSelect(day) }
    }

    private func recenter(on date: Date) {
        anchorDay = calendar.startOfDay(for: date)
        centeredStep = 0
    }

    private func tint(for day: Date) -> Color {
        let weekday = calendar.component(.weekday, from: day)
        if MapHomeCalendarDayStyle(date: day, calendar: calendar) == .holiday || weekday == 1 { return .tpSundayText }
        return weekday == 7 ? .tpSaturdayText : .tpInk
    }

    /// 가운데 오는 날짜 칸을 파랗게 강조한다. 밀면 강조도 같이 옮겨 간다.
    private func dayCell(step: Int, isCentered: Bool) -> some View {
        let day = date(forStep: step)
        let weekday = day.formatted(
            Date.FormatStyle().weekday(.narrow).locale(Locale(identifier: language.text("ko_KR", "en_US")))
        )
        return Button {
            onSelect(day)
        } label: {
            VStack(spacing: 0) {
                Text(weekday)
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(10)), weight: .semibold))
                    .foregroundStyle(tint(for: day))
                Text(String(calendar.component(.day, from: day)))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(16)), weight: .bold))
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
                if markedDays.contains(day) {
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
