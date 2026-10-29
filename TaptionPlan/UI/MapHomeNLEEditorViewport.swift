import SwiftUI

/// 클립 편집기의 화면 창: 스크롤 한계·처음 맞춤·눈금·지난 날 잇기(NLE1029A02).
///
/// 편집기 본문(`MapHomeNLEClipEditor.swift`)은 줄 예산이 묶여 있어, 여러 날로
/// 넓어진 창 계산을 여기로 뺀다. 위로 넘기면 전날을 읽어 앞에 잇고, 눈금은
/// 자정마다 날짜 줄을 긋고 시각은 24시간으로 감는다.
extension MapHomeNLEClipEditor {
    struct NLEEditorSnapshot: Equatable {
        var main: [NLEClip]
        var sub: [NLEClip]
        var selectedClipID: String?
        var selectedSubClipID: String?
    }

    /// 지금 화면 높이에 들어오는 분 수.
    var visibleSpanMinutes: Double {
        Double(max(1, containerHeight)) / Double(max(0.01, minuteHeight))
    }

    /// 읽어 둔 날 수(기준일 포함).
    var loadedDays: Int {
        (track.rangeEndMinute - track.rangeStartMinute) / NLETrack.dayMinutes
    }

    // MARK: - 스크롤

    /// 화면 맨 위를 옮긴다. 읽어 둔 범위 안에 묶고, 위쪽 끝에 다가오면 전날을 읽는다.
    func setVisibleStart(_ value: Double) {
        let lower = Double(track.rangeStartMinute)
        let maximum = max(lower, Double(track.rangeEndMinute) - visibleSpanMinutes)
        visibleStartMinute = min(max(value, lower), maximum)
        loadPreviousDayIfNeeded()
    }

    /// 처음 열면 기준일 24시간이 한눈에 들어오게 맞춘다. 확대는 두 손가락으로 한다.
    func fitWholeDayIfNeeded(height: CGFloat) {
        guard !didCenter, height > 1 else { return }
        didCenter = true
        if let initialMinuteHeight {
            minuteHeight = initialMinuteHeight
            let visible = Double(height) / Double(initialMinuteHeight)
            setVisibleStart(Double(focusMinute) - visible / 2)
            return
        }
        minuteHeight = max(0.22, height / CGFloat(NLETrack.dayMinutes))
        setVisibleStart(0)
    }

    // MARK: - 지난 날 잇기

    /// 화면 맨 위가 읽어 둔 범위의 시작에 한 화면 안으로 오면 전날을 읽는다. 한 번에 하루씩.
    func loadPreviousDayIfNeeded() {
        guard previousDayLoad == nil,
              NLEDayWindow.needsEarlierDay(
                  visibleStartMinute: visibleStartMinute,
                  visibleMinutes: visibleSpanMinutes,
                  rangeStartMinute: track.rangeStartMinute
              ) else { return }
        let window = NLEDayWindow(baseDate: date, loadedDays: loadedDays)
        previousDayLoad = Task { @MainActor in
            let day = await NLEDayWindow.loadDay(model: model, date: window.nextEarlierDate)
            prepend(day, dayOffset: window.nextEarlierOffset)
            previousDayLoad = nil
        }
    }

    /// 읽어 온 하루를 두 줄 앞에 잇는다. 되돌리기 기록도 같은 날을 앞에 이어,
    /// 되돌려도 지난 날이 사라지지 않게 한다.
    func prepend(_ day: NLEDayInput, dayOffset: Int) {
        let built = NLEDayWindow.clips(segments: day.segments, details: day.details, dayOffset: dayOffset)
        let previousStart = track.rangeStartMinute
        track = NLEDayWindow.prepending(built.main, to: track)
        subTrack = NLEDayWindow.prepending(built.sub, to: subTrack)
        undoStack = undoStack.map { rebased($0, with: built, rangeStartMinute: previousStart) }
        redoStack = redoStack.map { rebased($0, with: built, rangeStartMinute: previousStart) }
    }

    private func rebased(
        _ snapshot: NLEEditorSnapshot,
        with day: NLEDayClips,
        rangeStartMinute: Int
    ) -> NLEEditorSnapshot {
        var next = snapshot
        next.main = NLEDayWindow.prepending(
            day.main,
            to: NLETrack(clips: snapshot.main, rangeStartMinute: rangeStartMinute, rangeEndMinute: track.rangeEndMinute)
        ).snapshot()
        next.sub = NLEDayWindow.prepending(
            day.sub,
            to: NLETrack(
                clips: snapshot.sub, rangeStartMinute: rangeStartMinute,
                rangeEndMinute: track.rangeEndMinute, fillsGaps: false
            )
        ).snapshot()
        return next
    }

    // MARK: - 눈금

    /// 눈금선 간격. 하루 전체를 볼 때는 한 시간, 확대하면 30·15분.
    var gridStepMinutes: Int {
        switch minuteHeight {
        case ..<0.7: 60
        case ..<2.2: 30
        default: 15
        }
    }

    /// 눈금에 시각을 적는 간격. 하루 전체를 볼 때는 세 시간마다 적는다.
    var rulerLabelEveryMinutes: Int {
        switch minuteHeight {
        case ..<0.55: 180
        case ..<1.4: 60
        default: 30
        }
    }

    /// 눈금 글자. 정시는 "23", 그 사이는 "23:30"으로, 전날로 넘어가도 24시간으로 감는다.
    func rulerLabel(_ minute: Int) -> String {
        minute.isMultiple(of: 60)
            ? String(format: "%02d", NLEDayWindow.wrappedHour(minute))
            : Self.minuteLabel(minute)
    }

    func hourGrid(geometry: NLETimelineGeometry, width: CGFloat) -> some View {
        Canvas { context, size in
            let step = gridStepMinutes
            let labelEvery = rulerLabelEveryMinutes
            // 음수 분(지난 날)도 내림으로 맞춰 첫 눈금이 화면 위에서 시작한다.
            var minute = Int((geometry.visibleStartMinute / Double(step)).rounded(.down)) * step
            while Double(minute) <= geometry.visibleEndMinute {
                let y = geometry.y(forMinute: Double(minute))
                if y >= -1, y <= size.height + 1 {
                    let isDay = minute.isMultiple(of: NLETrack.dayMinutes)
                    let isHour = minute.isMultiple(of: 60)
                    var line = Path()
                    line.move(to: CGPoint(x: isHour ? gutterWidth : gutterWidth + 10, y: y))
                    line.addLine(to: CGPoint(x: size.width, y: y))
                    context.stroke(
                        line,
                        with: .color(
                            isDay ? Color.tpAccent.opacity(0.5)
                                : (isHour ? Color.tpInk.opacity(0.14) : Color.tpInk.opacity(0.06))
                        ),
                        lineWidth: isDay ? 1.2 : (isHour ? 1 : 0.6)
                    )
                    // 맨 위 00시가 카드 모서리에 잘리지 않게 안쪽으로 붙인다.
                    let labelY = min(max(y, 7), size.height - 7)
                    if minute.isMultiple(of: labelEvery) {
                        context.draw(
                            Text(rulerLabel(minute))
                                .font(.system(size: TaptionType.scaled(TaptionType.snapped(9)), weight: .semibold, design: .rounded))
                                .foregroundStyle(Color.tpSecondary),
                            at: CGPoint(x: gutterWidth - 7, y: labelY),
                            anchor: .trailing
                        )
                    }
                    // 자정 줄에는 그 날의 날짜를 눈금 아래에 적는다. 기준일 끝(24:00)에는 적지 않는다.
                    if isDay, minute < track.rangeEndMinute {
                        context.draw(
                            Text(NLEDayWindow.dayLabel(dayIndex: NLEDayWindow.dayIndex(minute), baseDate: date))
                                .font(.system(size: TaptionType.scaled(TaptionType.snapped(8)), weight: .bold, design: .rounded))
                                .foregroundStyle(Color.tpAccent),
                            at: CGPoint(x: gutterWidth - 7, y: labelY + 11),
                            anchor: .trailing
                        )
                    }
                }
                minute += step
            }
        }
        .allowsHitTesting(false)
    }
}
