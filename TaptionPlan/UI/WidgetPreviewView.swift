import SwiftUI

struct WidgetPreviewView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            DetailHeader(title: "위젯 미리보기", trailing: "완료") {
                model.detail = nil
            }

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: TaptionSpacing.regular) {
                    Text("홈 화면 · 중간 위젯")
                        .font(.taption(size: 12, weight: .bold))
                        .foregroundStyle(Color.tpInk.opacity(0.55))
                        .padding(.horizontal, 4)

                    widgetCard

                    Text("잠금 화면 · 현재 활동")
                        .font(.taption(size: 12, weight: .bold))
                        .foregroundStyle(Color.tpInk.opacity(0.55))
                        .padding(.horizontal, 4)
                        .padding(.top, 12)

                    liveCard
                }
                .padding(14)
            }
            .background(
                LinearGradient(
                    colors: [
                        Color(red: 0.86, green: 0.91, blue: 0.96),
                        Color(red: 0.93, green: 0.90, blue: 0.95),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
    }

    private var widgetCard: some View {
        VStack(spacing: 0) {
            HStack {
                HStack(spacing: TaptionSpacing.compact) {
                    Text("지금의 시간표")
                        .font(.taption(size: 13, weight: .bold))
                    Text("집중 중")
                        .font(.taption(size: 8, weight: .bold))
                        .foregroundStyle(Color(red: 0.57, green: 0.38, blue: 0.08))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.tpWarningTint, in: Capsule())
                    Text("\(model.selectedCatCoat.shortName) ▾")
                        .font(.taption(size: 8, weight: .bold))
                        .foregroundStyle(Color.tpSecondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.tpCard, in: Capsule())
                        .overlay { Capsule().stroke(Color.tpLine) }
                }
                Spacer()
                Label(widgetTrailingLabel, systemImage: weatherSymbol)
                    .font(.taption(size: 9, weight: .bold))
                    .foregroundStyle(Color.tpWeatherDark)
            }
            .padding(.bottom, 10)

            GeometryReader { proxy in
                let now = widgetFraction(Date.now)
                Rectangle().fill(Color.tpLine).frame(height: 0.5).position(x: proxy.size.width / 2, y: 0)
                RunningCatView(coat: model.selectedCatCoat)
                    .position(x: proxy.size.width * now, y: 19)
                ForEach(Array(widgetPlans.prefix(2).enumerated()), id: \.element.id) { index, plan in
                    let start = widgetFraction(plan.span.start)
                    let end = widgetFraction(plan.span.end)
                    let width = max(
                        20,
                        proxy.size.width * max(0.02, end - start)
                    )
                    RoundedRectangle(cornerRadius: TaptionRadius.tight)
                        .fill(categoryColor(plan.categoryID))
                        .frame(width: width, height: 24)
                        .overlay(alignment: .leading) {
                            Text(plan.title)
                                .font(.taption(size: 9.5, weight: .semibold))
                                .lineLimit(1)
                                .padding(.horizontal, 6)
                        }
                        .position(
                            x: proxy.size.width * start + width / 2,
                            y: 45 + CGFloat(index * 27)
                        )
                }
                Rectangle().fill(Color.tpNow).frame(width: 2, height: 42)
                    .position(x: proxy.size.width * now, y: 55)
            }
            .frame(height: 112)
            .overlay(alignment: .bottom) { Rectangle().fill(Color.tpLine).frame(height: 0.5) }
        }
        .padding(14)
        .background(Color.tpCard.opacity(0.94), in: RoundedRectangle(cornerRadius: 20))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 8)
    }

    private var liveCard: some View {
        VStack(spacing: 0) {
            HStack {
                Text(activeWidgetPlan?.title ?? "현재 실행 중인 계획 없음")
                    .font(.taption(size: 13, weight: .bold))
                Spacer()
                if let plan = activeWidgetPlan {
                    Text(
                        plan.span.end,
                        style: .relative
                    )
                    .font(.taption(size: 11))
                    .foregroundStyle(
                        Color(red: 0.78, green: 0.78, blue: 0.80)
                    )
                }
            }
            GeometryReader { proxy in
                Capsule().fill(Color(red: 0.21, green: 0.21, blue: 0.23))
                Capsule()
                    .fill(Color.tpStudyDark)
                    .frame(
                        width: proxy.size.width
                            * activeProgress
                    )
            }
            .frame(height: 6)
            .padding(.vertical, 13)
            HStack {
                Text(activeTimeLabel).font(.taption(size: 11))
                Spacer()
                if let planID = activeWidgetPlan?.id {
                    Button("종료") {
                        Task {
                            await model.performQuickAction(
                                .stopCurrentActivity,
                                planID: planID
                            )
                        }
                    }
                    .font(.taption(size: 11, weight: .bold))
                    .foregroundStyle(Color.tpInk)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 7)
                    .background(
                        .white,
                        in: RoundedRectangle(cornerRadius: TaptionRadius.panel)
                    )
                    .buttonStyle(.plain)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(14)
        .background(Color(red: 0.08, green: 0.08, blue: 0.09), in: RoundedRectangle(cornerRadius: 18))
    }

    private var widgetDaySpan: TimeSpan {
        TimelineAggregationEngine().interval(
            for: .day,
            containing: .now
        )
    }

    private var widgetPlans: [PlanRecord] {
        model.snapshot.plans
            .filter { $0.status != .skipped }
            .overlapping(widgetDaySpan, by: \.span)
    }

    private var activeWidgetPlan: PlanRecord? {
        widgetPlans.first {
            $0.status == .running || $0.span.contains(.now)
        } ?? widgetPlans.first { $0.span.start > .now }
    }

    private func widgetFraction(_ date: Date) -> CGFloat {
        widgetDaySpan.clampedFraction(of: date)
    }

    private func categoryColor(_ id: String) -> Color {
        guard let category = model.snapshot.categories.first(where: {
            $0.id == id
        }) else {
            return .tpProject
        }
        return Color(hex: category.lightHex)
    }

    private var activeProgress: CGFloat {
        guard let plan = activeWidgetPlan, plan.span.duration > 0 else {
            return 0
        }
        return max(
            0,
            min(
                1,
                CGFloat(
                    Date.now.timeIntervalSince(plan.span.start)
                        / plan.span.duration
                )
            )
        )
    }

    private var activeTimeLabel: String {
        guard let plan = activeWidgetPlan else {
            return "계획을 시작하면 잠금 화면에 표시됩니다"
        }
        return "\(plan.span.start.formatted(date: .omitted, time: .shortened)) → \(plan.span.end.formatted(date: .omitted, time: .shortened))"
    }

    private var currentWeather: WeatherContext? {
        model.snapshot.weather.min {
            abs($0.observedAt.timeIntervalSinceNow)
                < abs($1.observedAt.timeIntervalSinceNow)
        }
    }

    private var widgetTrailingLabel: String {
        let time = Date.now.formatted(date: .omitted, time: .shortened)
        guard let currentWeather else { return time }
        return "\(AppRegion.current.temperature(celsius: currentWeather.temperatureCelsius))° · \(time)"
    }

    private var weatherSymbol: String {
        currentWeather?.symbolName ?? "clock"
    }
}
