import CoreLocation
import SwiftUI
import TaptionPlanCore
import TaptionPlanStore

/// 「계획과 실제」(PVR1114A13): 고른 날의 계획(점선)과 실제 기록(실선)을 겹치거나 나란히 놓고 차이를 뱃지로 보인다.
/// 아래에는 계획·실제 경로 지도와, 밀렸거나 예산을 넘겼을 때의 「남은 일정 AI로 재조정」이 있다.
struct PlanRealityView: View {
    @Bindable var model: AppModel
    let language: MapHomeLanguage

    static let sentKey = "planRealityReplanSent"

    @Environment(\.dismiss) private var dismiss
    @State private var gap = PlanRealityGap.Day()
    @State private var actualRoute: [CLLocationCoordinate2D] = []
    @State private var notice: String?
    @State private var computedAt = Date.now

    private var book: LedgerBook { .shared }

    private var day: TimeSpan {
        let calendar = Calendar.autoupdatingCurrent
        let start = calendar.startOfDay(for: model.selectedDate)
        return TimeSpan(start: start, end: calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400))
    }

    private var stops: [TravelPlanStop] { TravelPlanSchedule.stops(on: day.start, in: model.settings.travelPlanStops) }

    /// 다시 셀 때: 날짜가 바뀌거나, 기록·장부가 저장됐을 때.
    private struct RefreshKey: Hashable {
        var day: Date
        var savedAt: Date
        var ledger: Int
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                PlanRealityContent(
                    gap: gap, dayStart: day.start, stops: stops, actualRoute: actualRoute, now: computedAt, language: language,
                    notice: notice, onReplan: replanAction
                )
                .padding(20)
            }
            .background(Color.tpBackground)
            .navigationTitle(language.text("계획과 실제", "Plan vs actual"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(language.text("닫기", "Close")) { dismiss() }
                }
            }
        }
        .task(id: RefreshKey(day: day.start, savedAt: model.snapshotSavedAt, ledger: book.revision)) {
            await book.load()
            recompute()
        }
        .task(id: day.start) {
            let span = day
            actualRoute = PlanRealityRoute.actual(model.mergingLiveSensorReadings(await model.sensorReadings(in: span), in: span), in: span)
        }
    }

    /// 중계 서버가 없는 빌드에서는 재조정 버튼이 없다.
    private var replanAction: (() -> Void)? {
        TripRelay.isAvailable ? { sendReplan() } : nil
    }

    /// 값이 실제로 바뀔 때만 화면 상태를 바꾼다.
    private func recompute() {
        let span = day, now = Date.now
        let snapshot = model.snapshot
        let next = PlanRealityGap.day(PlanRealityGap.Input(
            plans: snapshot.plans.filter { $0.span.intersection(with: span) != nil },
            actuals: snapshot.actuals.filter { $0.startedAt < span.end && ($0.endedAt ?? now) >= span.start },
            places: snapshot.places.filter { $0.span.intersection(with: span) != nil },
            stops: stops,
            tripItems: (snapshot.settings.travelTripItems ?? []).filter { $0.start < span.end && $0.end > span.start },
            entries: book.entries.filter { $0.tripID != nil && span.contains($0.occurredAt) },
            day: span, now: now
        ))
        if next != gap {
            gap = next
            computedAt = now
        }
    }

    private func sendReplan() {
        let now = Date.now
        let level = AssistantShareLevel.current()
        guard let text = PlanRealityText.summary(gap, level: level, language: language, now: now) else {
            notice = language.text("AI 공유가 꺼져 있어 보낼 수 없습니다. AI 연결에서 공유 수준을 바꿔 주세요.", "AI sharing is off. Change the share level in AI connections.")
            return
        }
        let signature = PlanRealityText.signature(gap, dayStart: day.start)
        guard UserDefaults.standard.string(forKey: Self.sentKey) != signature else {
            notice = language.text("같은 내용을 이미 보냈습니다.", "This was already sent.")
            return
        }
        guard AITaskQueue.enqueue(.replan, text: text, day: day.start.addingTimeInterval(12 * 3_600), context: PlanRealityText.context(gap, level: level, now: now)) else {
            notice = language.text("연결된 AI가 없습니다. 메뉴의 AI 연결에서 먼저 연결해 주세요.", "No AI is connected. Connect one in AI connections first.")
            return
        }
        UserDefaults.standard.set(signature, forKey: Self.sentKey)
        notice = language.text("AI 할 일에 올렸습니다. AI가 바꾸기 전에 먼저 물어봅니다.", "Sent to AI tasks. The AI asks you before changing anything.")
    }
}

/// 화면 내용. 값만 받아 그린다(미리보기도 같은 것을 쓴다).
struct PlanRealityContent: View {
    let gap: PlanRealityGap.Day
    let dayStart: Date
    let stops: [TravelPlanStop]
    let actualRoute: [CLLocationCoordinate2D]
    let now: Date
    let language: MapHomeLanguage
    var notice: String?
    /// nil이면 재조정 버튼을 보이지 않는다(중계 서버가 없는 빌드).
    var onReplan: (() -> Void)?

    @AppStorage("planRealitySplit") private var isSplit = false
    @State private var showsActualRoute = true

    var body: some View {
                LazyVStack(alignment: .leading, spacing: 14) {
                    header
                    if gap.items.isEmpty {
                        Text(language.text("이 날은 비교할 계획이 없습니다.", "No plans to compare on this day."))
                            .foregroundStyle(Color.tpSecondary)
                    } else {
                        if gap.plannedKRW > 0 || gap.spentKRW > 0 { PlanRealityBudgetBars(gap: gap, language: language) }
                        Picker("", selection: $isSplit) {
                            Text(language.text("겹쳐 보기", "Overlay")).tag(false)
                            Text(language.text("나란히 보기", "Side by side")).tag(true)
                        }
                        .pickerStyle(.segmented)
                        PlanRealityLegend(language: language)
                        if let range = gap.range {
                            ForEach(gap.items) { item in
                                PlanRealityRow(item: item, range: range, isSplit: isSplit, now: now, language: language)
                            }
                        }
                    }
                    if !stops.isEmpty || actualRoute.count >= 2 {
                        PlanRealityMap(stops: stops, actual: actualRoute, language: language, showsActual: $showsActualRoute)
                    }
                    if gap.needsReplan, onReplan != nil { replanSection }
                }
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.body)))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(dayStart, format: .dateTime.month().day().weekday())
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.headline), weight: .bold))
            if !gap.items.isEmpty {
                HStack(spacing: 6) {
                    if gap.isDelayed {
                        let late = PlanRealityText.time(gap.delay, language)
                        PlanRealityBadge(text: language.text("지연 \(late)", "Late \(late)"), tint: TravelInk.actual)
                    }
                    if gap.isOverBudget {
                        let over = PlanRealityText.money(gap.overKRW, language)
                        PlanRealityBadge(text: language.text("예산 \(over)", "Budget \(over)"), tint: TravelInk.actual)
                    }
                    if !gap.isDelayed, !gap.isOverBudget {
                        PlanRealityBadge(text: language.text("계획대로", "On plan"), tint: TravelInk.plan)
                    }
                }
            }
        }
    }

    private var replanSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { onReplan?() } label: {
                Label(language.text("남은 일정 AI로 재조정", "Replan the rest with AI"), systemImage: "sparkles")
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.bodyStrong), weight: .bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(TravelInk.plan)
            Text(notice ?? language.text("일정 시각과 차이, 예산 차이만 AI 할 일로 보냅니다. 좌표와 결제 정보는 보내지 않습니다.", "Only schedule times, gaps and the budget gap are sent as an AI task. No coordinates or payment details."))
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.caption)))
                .foregroundStyle(Color.tpSecondary)
        }
    }
}

/// 「+25분」「-5,000원」 같은 작은 뱃지.
struct PlanRealityBadge: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.caption), weight: .bold))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(tint.opacity(0.14), in: Capsule())
    }
}

/// 점선은 계획, 실선은 실제.
private struct PlanRealityLegend: View {
    let language: MapHomeLanguage

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 5) {
                PlanRealityBar(isPlan: true).frame(width: 30, height: 10)
                Text(language.text("계획", "Plan"))
            }
            HStack(spacing: 5) {
                PlanRealityBar(isPlan: false).frame(width: 30, height: 10)
                Text(language.text("실제", "Actual"))
            }
        }
        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.caption), weight: .semibold))
        .foregroundStyle(Color.tpSecondary)
    }
}

/// 막대 하나: 계획은 반투명 바탕에 점선 테두리, 실제는 채운 실선.
private struct PlanRealityBar: View {
    let isPlan: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 3, style: .continuous)
        if isPlan {
            shape.fill(TravelInk.plan.opacity(0.14))
                .overlay { shape.strokeBorder(TravelInk.plan.opacity(0.75), style: StrokeStyle(lineWidth: 1.2, dash: [3, 2.5])) }
        } else {
            shape.fill(TravelInk.actual.opacity(0.82))
        }
    }
}

/// 일정 한 줄: 제목·시각·차이 뱃지와, 하루 범위에 맞춘 계획·실제 막대.
private struct PlanRealityRow: View {
    let item: PlanRealityGap.Item
    let range: TimeSpan
    let isSplit: Bool
    let now: Date
    let language: MapHomeLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(item.title)
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.bodyStrong), weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let delta = item.timeBadge() {
                    PlanRealityBadge(text: PlanRealityText.time(delta, language), tint: delta > 0 ? TravelInk.actual : TravelInk.plan)
                }
                if let delta = item.costBadge() {
                    PlanRealityBadge(text: PlanRealityText.money(delta, language), tint: delta > 0 ? TravelInk.actual : TravelInk.plan)
                }
            }
            GeometryReader { proxy in
                let lane: CGFloat = isSplit ? 10 : 14
                ZStack(alignment: .topLeading) {
                    bar(item.plan, isPlan: true, width: proxy.size.width, height: lane, y: 0)
                    if let actual = item.actual {
                        // 겹칠 때는 실제를 조금 얇게 그려 계획의 점선 테두리가 보이게 한다.
                        bar(actual, isPlan: false, width: proxy.size.width, height: isSplit ? lane : lane - 6, y: isSplit ? lane + 3 : 3)
                    }
                }
            }
            .frame(height: isSplit ? 23 : 14)
            Text(caption)
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.caption)))
                .foregroundStyle(Color.tpSecondary)
                .lineLimit(1)
        }
        .padding(10)
        .background(Color.tpCard, in: RoundedRectangle(cornerRadius: TaptionCorner.medium, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func bar(_ span: TimeSpan, isPlan: Bool, width: CGFloat, height: CGFloat, y: CGFloat) -> some View {
        let total = max(1, range.duration)
        let start = CGFloat(span.start.timeIntervalSince(range.start) / total) * width
        let length = max(3, CGFloat(span.duration / total) * width)
        return PlanRealityBar(isPlan: isPlan)
            .frame(width: min(length, max(3, width - start)), height: height)
            .offset(x: min(start, max(0, width - 3)), y: y)
    }

    private var caption: String {
        let plan = PlanRealityText.clock(item.plan)
        var parts = [language.text("계획 \(plan)", "Plan \(plan)")]
        if let span = item.actual {
            let actual = PlanRealityText.clock(span)
            parts.append(item.isOngoing ? language.text("실제 \(actual) · 진행 중", "Actual \(actual) · ongoing") : language.text("실제 \(actual)", "Actual \(actual)"))
        } else {
            parts.append(item.plan.end > now ? language.text("아직 전", "Not yet") : language.text("기록 없음", "No record"))
        }
        if let planned = item.plannedKRW {
            let amount = LedgerMoney.text(planned, language: language)
            parts.append(language.text("예산 \(amount)", "Budget \(amount)"))
        }
        if let spent = item.spentKRW, spent > 0 {
            let amount = LedgerMoney.text(spent, language: language)
            parts.append(language.text("쓴 돈 \(amount)", "Spent \(amount)"))
        }
        return parts.joined(separator: " · ")
    }
}

/// 그날의 계획 지출(점선)과 쓴 돈(실선).
private struct PlanRealityBudgetBars: View {
    let gap: PlanRealityGap.Day
    let language: MapHomeLanguage

    var body: some View {
        let top = max(gap.plannedKRW, gap.spentKRW, 1)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(language.text("예산", "Budget"))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.bodyStrong), weight: .semibold))
                Spacer(minLength: 4)
                if gap.plannedKRW > 0, abs(gap.overKRW) >= PlanRealityGap.Thresholds.standard.costBadgeKRW {
                    PlanRealityBadge(text: PlanRealityText.money(gap.overKRW, language), tint: gap.overKRW > 0 ? TravelInk.actual : TravelInk.plan)
                }
            }
            line(language.text("계획", "Plan"), gap.plannedKRW, top: top, isPlan: true)
            line(language.text("실제", "Actual"), gap.spentKRW, top: top, isPlan: false)
        }
        .padding(10)
        .background(Color.tpCard, in: RoundedRectangle(cornerRadius: TaptionCorner.medium, style: .continuous))
    }

    private func line(_ title: String, _ amount: Double, top: Double, isPlan: Bool) -> some View {
        HStack(spacing: 8) {
            Text(title).frame(width: 44, alignment: .leading)
            GeometryReader { proxy in
                PlanRealityBar(isPlan: isPlan).frame(width: max(3, proxy.size.width * CGFloat(amount / top)))
            }
            .frame(height: 10)
            Text(LedgerMoney.text(amount, language: language)).monospacedDigit()
        }
        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.caption)))
        .foregroundStyle(Color.tpSecondary)
    }
}

#if DEBUG
/// 화면 모양 확인용(PVR1114A13, Debug 전용): `-planRealityPreview`. 지어낸 하루를 보인다.
struct PlanRealityPreviewHost: View {
    var body: some View {
        let start = Calendar.autoupdatingCurrent.startOfDay(for: .now)
        func span(_ from: Double, _ to: Double) -> TimeSpan { TimeSpan(start: start.addingTimeInterval(from * 3_600), end: start.addingTimeInterval(to * 3_600)) }
        func stop(_ order: Int, _ latitude: Double, _ longitude: Double) -> TravelPlanStop {
            TravelPlanStop(id: UUID(), title: "곳 \(order + 1)", latitude: latitude, longitude: longitude, day: start, order: order, planID: nil)
        }
        var gap = PlanRealityGap.Day(items: [
            .init(id: "1", title: "아침 산책", plan: span(8, 9), actual: span(8, 9.05), match: .linked),
            .init(id: "2", title: "박물관", plan: span(10, 11.5), actual: span(10.42, 12.2), match: .place, plannedKRW: 20_000, spentKRW: 15_000),
            .init(id: "3", title: "점심", plan: span(12, 13), actual: span(12.5, 13.6), match: .place, plannedKRW: 30_000, spentKRW: 42_000),
            .init(id: "4", title: "전망대", plan: span(14, 15.5)),
            .init(id: "5", title: "저녁", plan: span(18, 19.5), plannedKRW: 50_000),
        ])
        gap.plannedKRW = 100_000
        gap.plannedSoFarKRW = 50_000
        gap.spentKRW = 57_000
        gap.delay = 36 * 60
        gap.isDelayed = true
        gap.isOverBudget = true
        gap.remaining = 2
        return ScrollView {
            PlanRealityContent(
                gap: gap, dayStart: start, stops: [stop(0, 36.00, 128.00), stop(1, 36.02, 128.03), stop(2, 36.05, 128.02)],
                actualRoute: [(36.00, 128.00), (36.008, 128.018), (36.022, 128.026), (36.03, 128.04), (36.046, 128.024)].map { CLLocationCoordinate2D(latitude: $0.0, longitude: $0.1) },
                now: start.addingTimeInterval(13.7 * 3_600), language: .korean, onReplan: {}
            )
            .padding(20)
        }
        .background(Color.tpBackground)
    }
}
#endif
