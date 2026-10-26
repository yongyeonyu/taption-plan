import SwiftUI

/// 오른쪽 위 날짜 배지를 눌러 펼치는 날짜 줄.
///
/// 선택일을 가운데 두는 홀수 칸 창을 그린다. 좌우로 밀 때마다 창이 하루씩 옮겨 가
/// 새 날짜가 계속 들어오므로 끝이 없다(대표 지적: "좌우로 계속 날짜가 나오게").
/// 예전에는 달력 주(일~토)를 그대로 그려, 주말에 닿으면 더 갈 곳이 없어 보였다.
struct MapHomeDateStrip: View {
    let language: MapHomeLanguage
    let selectedDate: Date
    /// 날짜 칸을 눌렀거나 쓸어 넘겨 날짜가 바뀌었을 때. 부모가 선택일을 바꾼다.
    let onSelect: (Date) -> Void

    /// 손가락을 따라 움직인 거리. 한 칸(38pt)까지만 따라온다.
    @State private var dragOffset: CGFloat = 0

    private var calendar: Calendar { TimelineAxisGrid.normalizedCalendar() }

    var body: some View {
        let days = MapHomeWeekStripMath.window(around: selectedDate, calendar: calendar)
        HStack(spacing: MapHomeWeekStripMath.daySpacing) {
            ForEach(days, id: \.self) { day in
                dayCell(day)
            }
        }
        // 창 밖으로 나간 날짜는 잘라 낸다. 그래야 줄이 통째로 밀려 유리창이 어긋나 보이지 않는다.
        .offset(x: dragOffset)
        .clipped()
        .padding(.horizontal, 6)
        .frame(height: MapHomeWeekStripMath.height)
        .simultaneousGesture(swipeGesture)
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

    /// 좌우로 밀면 **한 번에 하루**씩 넘긴다.
    ///
    /// 예전에는 손가락이 움직인 거리에 비례해 날짜를 넘겼다(`dx / dayPitch`).
    /// 줄 폭이 한 주(274pt)라 한 번 쓸어 넘기면 6~7일이 지나 손짓 하나가
    /// '주 단위'로 보였다(대표 지적). 손가락은 한 칸까지만 따라오고, 실제로
    /// 넘어가는 날은 손짓 하나에 하루다.
    ///
    /// 줄은 선택일을 가운데 두는 창이라, 하루 넘길 때 내용이 손가락 반대쪽으로
    /// 한 칸 튄다. 그만큼을 `dragOffset`에 미리 더해 두고 0으로 되돌리면 날짜가
    /// 끊기지 않고 이어져 흐른다.
    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 14)
            .onChanged { value in
                let dx = value.translation.width
                guard abs(dx) > abs(value.translation.height) * 1.5 else { return }
                let pitch = MapHomeWeekStripMath.dayPitch
                dragOffset = min(pitch, max(-pitch, dx))
            }
            .onEnded { value in
                let dx = value.translation.width
                let isHorizontal = abs(dx) > abs(value.translation.height) * 1.5
                let pitch = MapHomeWeekStripMath.dayPitch
                // 반 칸을 넘겨야 넘긴다. 스치듯 지나간 손짓에 날짜가 바뀌면
                // 화면을 보려고 쓸었을 뿐인 손이 날짜를 바꾼다.
                if isHorizontal, abs(dx) >= pitch / 2,
                   let next = calendar.date(
                       byAdding: .day,
                       value: dx < 0 ? 1 : -1,
                       to: selectedDate
                   ) {
                    // 창이 하루 옮겨 간 만큼을 미리 상쇄한다(위 설명). 반 칸만 밀었으면
                    // 손가락 자리에 그대로 서 있다가 다음 런루프에서 제자리로 미끄러진다.
                    // 같은 런루프에서 되돌리면 두 변경이 한 번에 합쳐져 애니메이션이 사라진다.
                    dragOffset += dx < 0 ? pitch : -pitch
                    onSelect(next)
                    Task { @MainActor in
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                            dragOffset = 0
                        }
                    }
                    return
                }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { dragOffset = 0 }
            }
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
    static func window(around date: Date, calendar: Calendar) -> [Date] {
        let base = calendar.startOfDay(for: date)
        return (-windowRadius...windowRadius).compactMap {
            calendar.date(byAdding: .day, value: $0, to: base)
        }
    }
}
