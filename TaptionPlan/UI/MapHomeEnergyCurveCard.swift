import SwiftUI
import TaptionPlanCore

/// 하루 요약의 「컨디션 에너지 곡선」 카드(ENC1119A01). 자기 `@State`로 값을 받아 지도 화면 본문을 다시 그리지 않는다.
/// 값은 시트가 열릴 때·날짜가 바뀔 때·수면·계획·기록 개정이 바뀔 때만 다시 계산한다.
struct MapHomeEnergyCurveCard: View {
    let day: Date
    let language: MapHomeLanguage
    var model: AppModel?
    let make: @MainActor (Date) async -> EnergyCurveResult?
    @State private var result: EnergyCurveResult?
    @State private var isLoaded = false

    private struct Key: Equatable {
        var day: Date
        var revision: UInt64
        var sleepCount: Int
        var planCount: Int
    }

    private var key: Key {
        Key(day: Calendar.autoupdatingCurrent.startOfDay(for: day), revision: model?.dayProjectionRevision ?? 0,
            sleepCount: model?.sleepSessions.count ?? 0, planCount: model?.snapshot.plans.count ?? 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(language.text("컨디션 에너지 곡선", "Condition energy curve"))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(15)), weight: .bold))
                    .foregroundStyle(Color.tpInk)
                Text(day.formatted(Date.FormatStyle().month().day().weekday().locale(language.locale)))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .medium))
                    .foregroundStyle(Color.tpSecondary)
            }
            if let result, !result.isEmpty {
                MapHomeEnergyCurveChart(result: result, language: language).equatable()
                ForEach(Array(result.insights.enumerated()), id: \.offset) { _, insight in
                    insightRow(insight, result: result)
                }
            } else if isLoaded {
                Text(Self.insightLine(.noData, day: day, language: language))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .medium))
                    .foregroundStyle(Color.tpSecondary)
                    .accessibilityIdentifier("daySummaryEnergyCurveEmpty")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        .taptionRaised(.rounded(TaptionCorner.large), fill: Color.tpSurface, gloss: false)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier("daySummaryEnergyCurve")
        .task(id: key) {
            let next = await make(day)
            if next != result { result = next }
            isLoaded = true
        }
    }

    private func insightRow(_ insight: EnergyCurveInsight, result: EnergyCurveResult) -> some View {
        Text(Self.insightLine(insight, day: result.day?.start ?? day, language: language))
            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .medium))
            .foregroundStyle(Color.tpInk)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var accessibilityLabel: String {
        let title = language.text("컨디션 에너지 곡선", "Condition energy curve")
        guard let result, !result.isEmpty else { return title }
        let low = result.insights.compactMap { insight -> String? in
            if case let .lowestPoint(minute, value) = insight {
                let time = MapHomeAlarmPolicy.timeText((result.day?.start ?? day).addingTimeInterval(Double(minute) * 60), language: language)
                return language.runtimeText("가장 낮은 때 \(time) \(Int((value * 100).rounded()))%", "Lowest at \(time), \(Int((value * 100).rounded()))%")
            }
            return nil
        }.first
        let count = result.blocks.count
        let events = language.runtimeText("일정 \(count)건", "\(count) events")
        return [title, low, events].compactMap { $0 }.joined(separator: ", ")
    }

    /// 인사이트 문장(엔진은 문장을 만들지 않는다).
    static func insightLine(_ insight: EnergyCurveInsight, day: Date, language: MapHomeLanguage) -> String {
        func time(_ minute: Int) -> String { MapHomeAlarmPolicy.timeText(day.addingTimeInterval(Double(minute) * 60), language: language) }
        func percent(_ value: Double) -> Int { Int((value * 100).rounded()) }
        func span(_ seconds: TimeInterval) -> String { DurationText.localized(seconds, english: language == .english) }
        switch insight {
        case let .lowestPoint(minute, value):
            return language.text("\(time(minute)) 무렵 가장 낮아요 · 에너지 \(percent(value))%", "Lowest around \(time(minute)) · energy \(percent(value))%")
        case let .scheduleStack(_, count, seconds):
            return language.text("그 무렵 일정 \(count)건(\(span(seconds)))이 겹쳐요", "\(count) events (\(span(seconds))) overlap around then")
        case let .shortSleep(minutes):
            return language.text("어젯밤 \(span(Double(minutes) * 60)) 밤잠이라 시작이 낮아요", "Only \(span(Double(minutes) * 60)) of sleep last night, so the start is low")
        case .missingSleep:
            return language.text("어젯밤 수면 기록이 없어 기본값으로 그렸어요", "No sleep record last night, so the default start is used")
        case .noData:
            return language.text("이 날은 그릴 기록이 없어요", "Nothing to draw for this day")
        }
    }
}

/// 곡선·수면 띠·일정 띠 그림. 값이 같으면 다시 그리지 않는다(`Equatable`).
struct MapHomeEnergyCurveChart: View, Equatable {
    let result: EnergyCurveResult
    let language: MapHomeLanguage

    static let curveHeight: CGFloat = 130
    static let laneHeight: CGFloat = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Canvas { context, size in draw(context: &context, size: size) }
                .frame(height: Self.curveHeight)
            Canvas { context, size in drawLane(context: &context, size: size) }
                .frame(height: Self.laneHeight * CGFloat(max(1, laneRows)))
        }
        .accessibilityHidden(true)
    }

    private static let leftMargin: CGFloat = 28
    private static let bottomMargin: CGFloat = 16

    private func plot(_ size: CGSize) -> CGRect {
        CGRect(x: Self.leftMargin, y: 4, width: max(1, size.width - Self.leftMargin - 4), height: max(1, size.height - Self.bottomMargin - 4))
    }

    private func draw(context: inout GraphicsContext, size: CGSize) {
        let rect = plot(size)
        let count = max(1, result.buckets.count)
        func x(_ index: Int) -> CGFloat { rect.minX + rect.width * (CGFloat(index) + 0.5) / CGFloat(count) }
        func y(_ value: Double) -> CGFloat { rect.maxY - rect.height * CGFloat(value) }
        let label = Font.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .regular)

        for fraction in [0.0, 0.5, 1.0] {
            var grid = Path()
            grid.move(to: CGPoint(x: rect.minX, y: y(fraction)))
            grid.addLine(to: CGPoint(x: rect.maxX, y: y(fraction)))
            context.stroke(grid, with: .color(Color.tpLine.opacity(0.5)), lineWidth: 0.5)
            context.draw(context.resolve(Text("\(Int(fraction * 100))").font(label).foregroundStyle(Color.tpSecondary)), at: CGPoint(x: rect.minX - 4, y: y(fraction)), anchor: .trailing)
        }
        let hours = size.width < 260 ? [0, 12, 24] : [0, 6, 12, 18, 24]
        for hour in hours {
            let px = rect.minX + rect.width * CGFloat(hour) / 24
            context.draw(context.resolve(Text("\(hour)").font(label).foregroundStyle(Color.tpSecondary)), at: CGPoint(x: px, y: rect.maxY + 9), anchor: .center)
        }
        // 수면 구간
        var index = 0
        while index < result.buckets.count {
            guard result.buckets[index].isAsleep else { index += 1; continue }
            var end = index
            while end + 1 < result.buckets.count, result.buckets[end + 1].isAsleep { end += 1 }
            let left = rect.minX + rect.width * CGFloat(index) / CGFloat(count), right = rect.minX + rect.width * CGFloat(end + 1) / CGFloat(count)
            context.fill(Path(CGRect(x: left, y: rect.minY, width: right - left, height: rect.height)), with: .color(Color.tpLine.opacity(0.35)))
            index = end + 1
        }
        // 실제(실선+면)와 예측(점선). 두 줄이 이어지도록 예측은 마지막 실제 점에서 시작한다.
        let points: [(Int, CGPoint, Bool)] = result.buckets.enumerated().compactMap { offset, bucket in
            guard let value = bucket.value else { return nil }
            return (offset, CGPoint(x: x(offset), y: y(value)), bucket.isProjected)
        }
        let actual = points.filter { !$0.2 }.map(\.1), projected = points.filter { $0.2 }.map(\.1)
        if let first = actual.first, let last = actual.last {
            var area = Path()
            area.move(to: CGPoint(x: first.x, y: rect.maxY))
            actual.forEach { area.addLine(to: $0) }
            area.addLine(to: CGPoint(x: last.x, y: rect.maxY))
            area.closeSubpath()
            context.fill(area, with: .color(Color.tpAccent.opacity(0.12)))
            var line = Path()
            line.move(to: first)
            actual.dropFirst().forEach { line.addLine(to: $0) }
            context.stroke(line, with: .color(Color.tpAccent), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
        if let first = projected.first {
            var line = Path()
            line.move(to: actual.last ?? first)
            projected.forEach { line.addLine(to: $0) }
            context.stroke(line, with: .color(Color.tpAccent.opacity(0.8)), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round, dash: [4, 4]))
        }
    }

    /// 겹치는 일정은 위아래 줄로 나눈다.
    private var laneAssignments: [(block: EnergyCurveBlock, row: Int)] {
        var ends: [Date] = []
        return result.blocks.sorted { $0.span.start < $1.span.start }.map { block in
            if let row = ends.firstIndex(where: { $0 <= block.span.start }) {
                ends[row] = block.span.end
                return (block, row)
            }
            ends.append(block.span.end)
            return (block, ends.count - 1)
        }
    }

    private var laneRows: Int { min(3, (laneAssignments.map(\.row).max() ?? -1) + 1) }

    private func drawLane(context: inout GraphicsContext, size: CGSize) {
        guard let day = result.day, day.duration > 0 else { return }
        let rect = plot(CGSize(width: size.width, height: 100))
        for (block, row) in laneAssignments where row < 3 {
            let start = max(day.start, block.span.start), end = min(day.end, block.span.end)
            guard end > start else { continue }
            let left = rect.minX + rect.width * CGFloat(start.timeIntervalSince(day.start) / day.duration)
            let right = rect.minX + rect.width * CGFloat(end.timeIntervalSince(day.start) / day.duration)
            let bar = CGRect(x: left, y: CGFloat(row) * Self.laneHeight + 1, width: max(2, right - left), height: Self.laneHeight - 3)
            context.fill(Path(roundedRect: bar, cornerRadius: 3), with: .color(Color.tpReferenceBlue.opacity(0.6)))
        }
    }
}

// MARK: 입력 모으기

extension MapHomeView {
    /// 그날 수면·기록·계획·달력 일정을 모아 곡선을 계산한다. 다른 날 자료가 섞이지 않게 그날과 겹치는 것만 쓴다.
    /// 15분 칸 걸음 수는 넘기지 않는다(엔진은 받을 수 있다) — 하루 표본을 칸마다 다시 훑는 비용이 곡선에 비해 크다.
    @MainActor
    func energyCurve(for day: Date) async -> EnergyCurveResult? {
        let calendar = MapHomeGrowthPolicy.localCalendar
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
        let span = TimeSpan(start: start, end: end)
        let now = Date.now
        let isSelected = calendar.isDate(day, inSameDayAs: model.selectedDate)

        let window = TimeSpan(start: start.addingTimeInterval(-12 * 3_600), end: start.addingTimeInterval(12 * 3_600))
        let sleep = model.sleepSessions
            .filter { $0.span.end > window.start && $0.span.start < window.end }
            .max { $0.asleepDuration < $1.asleepDuration }
            .map { EnergyCurveSleep(asleep: $0.asleepDuration, deep: $0.stageDurations[.deep] ?? 0, efficiency: $0.sleepEfficiency, span: $0.span) }

        let actuals = (isSelected ? currentDayDataSnapshot?.actuals : nil) ?? model.snapshot.actuals
        let segments = actuals.compactMap { actual -> EnergyCurveSegment? in
            let actualSpan = actual.span(asOf: now)
            guard actualSpan.end > start, actualSpan.start < end, actualSpan.duration > 0 else { return nil }
            return EnergyCurveSegment(span: actualSpan, kind: EnergyCurveActivityKind.kind(forCategoryID: RecordAnalysisCategoryPolicy.categoryID(for: actual)))
        }

        // 달력에서 온 계획은 달력 일정과 겹치므로 빼고, 달력 일정으로 한 번만 센다. 종일 일정은 뺀다.
        let plans = model.snapshot.plans.filter { $0.externalEventID == nil && $0.status != .skipped && $0.span.end > start && $0.span.start < end }
        var blocks = plans.map { EnergyCurveBlock(span: $0.span, kind: EnergyCurveActivityKind.kind(forCategoryID: $0.categoryID)) }
        if isSelected {
            blocks += dayCalendarEventsForSelectedDate
                .filter { !$0.isAllDay && $0.span.end > start && $0.span.start < end }
                .map { EnergyCurveBlock(span: $0.span, kind: .unconfirmed) }
        }
        return EnergyCurveEngine.curve(EnergyCurveInput(day: span, asOf: now, sleep: sleep, segments: segments, blocks: blocks))
    }
}
