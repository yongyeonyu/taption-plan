import SwiftUI

struct ReviewView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            reviewHeader

            ScrollView(showsIndicators: false) {
                VStack(spacing: 10) {
                    recapHero

                    LazyVGrid(
                        columns: [GridItem(.flexible()), GridItem(.flexible())],
                        spacing: 8
                    ) {
                        if report.categories.isEmpty {
                            reviewCard(
                                "기록 없음",
                                value: "0분",
                                caption: "계획을 실행하면 차이가 여기에 쌓입니다."
                            )
                        } else {
                            ForEach(Array(report.categories.prefix(6))) { category in
                                reviewCard(
                                    categoryName(category.categoryID),
                                    value: durationText(category.actual),
                                    caption: differenceText(category)
                                )
                            }
                        }
                    }

                    contextCard
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .background(Color.tpBackground)
        }
    }

    private var reviewHeader: some View {
        VStack(spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(model.reviewScale.periodName) 회고")
                    .font(.system(size: 19, weight: .bold))
                Spacer()
                Text(periodText(report.span))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.tpSecondary)
            }

            HStack(spacing: 0) {
                ForEach(ReviewScale.allCases) { scale in
                    Button {
                        model.reviewScale = scale
                    } label: {
                        Text(scale.rawValue)
                            .font(.system(size: 12.5, weight: model.reviewScale == scale ? .semibold : .regular))
                            .foregroundStyle(model.reviewScale == scale ? Color.tpInk : Color.tpSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                            .background {
                                if model.reviewScale == scale {
                                    RoundedRectangle(cornerRadius: 7)
                                        .fill(.white)
                                        .shadow(color: .black.opacity(0.12), radius: 1.5, y: 1)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
            .background(
                Color(red: 0.93, green: 0.93, blue: 0.94),
                in: RoundedRectangle(cornerRadius: 9)
            )
        }
        .padding(.horizontal, 10)
        .padding(.top, 5)
        .padding(.bottom, 8)
        .background(Color.white)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.tpLine).frame(height: 0.5)
        }
    }

    private var recapHero: some View {
        let ratio = report.plannedDuration > 0
            ? min(1, report.actualDuration / report.plannedDuration)
            : 0
        let difference = report.actualDuration - report.plannedDuration

        return VStack(alignment: .leading, spacing: 0) {
            Text(
                "계획 \(durationText(report.plannedDuration)) · 실제 \(durationText(report.actualDuration))"
            )
                .font(.system(size: 10))
                .foregroundStyle(Color(red: 0.68, green: 0.68, blue: 0.70))
            Text(difference == 0 ? "차이 없음" : signedDurationText(difference))
                .font(.system(size: 24, weight: .bold))
                .padding(.vertical, 5)
            Text("점수가 아니라 \(model.reviewScale.periodName) 시간의 차이")
                .font(.system(size: 10))
                .foregroundStyle(Color(red: 0.68, green: 0.68, blue: 0.70))

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.18))
                    Capsule()
                        .fill(Color.tpProjectDark)
                        .frame(width: proxy.size.width * ratio)
                }
            }
            .frame(height: 9)
            .padding(.top, 11)
        }
        .foregroundStyle(.white)
        .padding(15)
        .background(Color.tpInk, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func reviewCard(_ title: String, value: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(Color.tpSecondary)
            Text(value)
                .font(.system(size: 16, weight: .bold))
                .padding(.top, 5)
                .padding(.bottom, 2)
            Text(caption)
                .font(.system(size: 10))
                .foregroundStyle(Color.tpSecondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 78, alignment: .topLeading)
        .padding(11)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    private var contextCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("\(model.reviewScale.periodName)을 설명한 기록")
                .font(.system(size: 11, weight: .bold))
            if report.contexts.isEmpty {
                contextLine(
                    "tray",
                    "사진·날씨·메모가 연결되면 이번 기간의 맥락을 보여드립니다."
                )
            } else {
                ForEach(report.contexts) { context in
                    contextLine(context.symbolName, context.text)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    private func contextLine(_ image: String, _ text: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: image)
                .font(.system(size: 13))
                .foregroundStyle(Color.tpSecondary)
                .frame(width: 14)
            Text(text)
                .font(.system(size: 10.5))
        }
    }

    private var report: ReviewReport {
        ReviewEngine().report(
            for: model.reviewScale.timelineLevel,
            containing: model.selectedDate,
            plans: model.snapshot.plans,
            actuals: model.snapshot.actuals,
            weather: model.snapshot.weather,
            photos: model.snapshot.photos,
            memos: model.snapshot.memos
        )
    }

    private func periodText(_ span: TimeSpan) -> String {
        span.start.formatted(.dateTime.month().day())
            + " – "
            + span.end.addingTimeInterval(-1).formatted(.dateTime.month().day())
    }

    private func categoryName(_ id: String) -> String {
        model.snapshot.categories.first { $0.id == id }?.name
            ?? PlanCategory(categoryID: id).rawValue
    }

    private func durationText(_ interval: TimeInterval) -> String {
        let totalMinutes = max(0, Int(interval / 60))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours == 0 { return "\(minutes)분" }
        if minutes == 0 { return "\(hours)시간" }
        return "\(hours)시간 \(minutes)분"
    }

    private func signedDurationText(_ interval: TimeInterval) -> String {
        let prefix = interval > 0 ? "＋" : "－"
        return prefix + durationText(abs(interval))
    }

    private func differenceText(_ category: CategoryDuration) -> String {
        let difference = category.actual - category.planned
        if abs(difference) < 60 {
            return "계획과 실제가 같습니다."
        }
        return difference > 0
            ? "계획보다 \(durationText(difference)) 더 사용"
            : "계획보다 \(durationText(abs(difference))) 적음"
    }
}

private extension ReviewScale {
    var periodName: String {
        switch self {
        case .week: "이번 주"
        case .month: "이번 달"
        case .year: "올해"
        }
    }

    var timelineLevel: TimelineLevel {
        switch self {
        case .week: .week
        case .month: .month
        case .year: .year
        }
    }
}

#Preview {
    ReviewView(model: AppModel())
}
