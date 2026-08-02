import SwiftUI

private struct ActualRecordItem: Identifiable {
    let id: String
    let record: ActualRecord
    let span: TimeSpan
    let totalDuration: TimeInterval
    let occurrenceCount: Int
    let timeRanges: [TimeSpan]
}

private struct ActualCategoryGroup: Identifiable {
    let id: String
    let name: String
    let items: [ActualRecordItem]
}

private struct ActualPeriodGroup: Identifiable {
    let id: String
    let label: String
    let categories: [ActualCategoryGroup]
}

struct ReviewView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            reviewHeader

            ScrollView(showsIndicators: false) {
                VStack(spacing: 10) {
                    recapHero
                    planBreakdownCard
                    if model.reviewScale != .week {
                        hierarchySummaryCard
                    }
                    actualRecordsCard
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
                Text("\(model.reviewScale.periodName) 기록")
                    .font(.taption(size: 19, weight: .bold))
                Spacer()
                Text(periodText(report.span))
                    .font(.taption(size: 12))
                    .foregroundStyle(Color.tpSecondary)
            }

            HStack(spacing: 0) {
                ForEach(ReviewScale.allCases) { scale in
                    Button {
                        model.reviewScale = scale
                    } label: {
                        Text(scale.rawValue)
                            .font(.taption(size: 12.5, weight: model.reviewScale == scale ? .semibold : .regular))
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
                .font(.taption(size: 10))
                .foregroundStyle(Color(red: 0.68, green: 0.68, blue: 0.70))
            Text(difference == 0 ? "차이 없음" : signedDurationText(difference))
                .font(.taption(size: 24, weight: .bold))
                .padding(.vertical, 5)
            Text("점수가 아니라 \(model.reviewScale.periodName) 계획과 실제")
                .font(.taption(size: 10))
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

    private var planBreakdownCard: some View {
        let plannedCategories = report.categories
            .filter { $0.planned > 0 }

        return VStack(alignment: .leading, spacing: 8) {
            Label("계획", systemImage: "calendar.badge.clock")
                .font(.taption(size: 11, weight: .bold))

            if plannedCategories.isEmpty {
                Text("이 기간에 등록된 계획이 없습니다.")
                    .font(.taption(size: 10.5))
                    .foregroundStyle(Color.tpSecondary)
            } else {
                ForEach(plannedCategories) { category in
                    HStack(spacing: 8) {
                        Text(categoryName(category.categoryID))
                            .font(.taption(size: 10, weight: .semibold))
                        Spacer(minLength: 4)
                        Text("계획 \(durationText(category.planned))")
                            .font(.taption(size: 9))
                            .foregroundStyle(Color.tpSecondary)
                        if category.actual > 0 {
                            Text("실제 \(durationText(category.actual))")
                                .font(.taption(size: 9, weight: .semibold))
                                .foregroundStyle(Color.tpProjectDark)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    private var actualRecordsCard: some View {
        let records = actualRecordItems
        let groups = actualPeriodGroups
        let itemCount = groups.reduce(0) { total, period in
            total + period.categories.reduce(0) { total, category in
                total + category.items.count
            }
        }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label("실제 기록", systemImage: "checkmark.circle")
                    .font(.taption(size: 11, weight: .bold))
                Spacer()
                Text("\(itemCount)개 항목")
                    .font(.taption(size: 9))
                    .foregroundStyle(Color.tpSecondary)
            }

            if records.isEmpty {
                Text("이 기간에 저장된 실제 데이터가 없습니다.")
                    .font(.taption(size: 10.5))
                    .foregroundStyle(Color.tpSecondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(groups) { period in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(period.label)
                                .font(.taption(size: 11, weight: .bold))
                                .foregroundStyle(Color.tpInk)
                                .padding(.top, 3)

                            ForEach(period.categories) { category in
                                VStack(alignment: .leading, spacing: 1) {
                                    Label(category.name, systemImage: PlanCategory(categoryID: category.id).systemImage)
                                        .font(.taption(size: 9.5, weight: .semibold))
                                        .foregroundStyle(PlanCategory(categoryID: category.id).darkColor)
                                        .padding(.top, 2)
                                    ForEach(category.items) { item in
                                        actualRecordRow(item, showsCategory: false)
                                    }
                                }
                                .padding(.leading, 5)
                            }
                        }
                        .padding(.bottom, 3)
                        .overlay(alignment: .bottom) {
                            if period.id != groups.last?.id {
                                Rectangle()
                                    .fill(Color.tpLine.opacity(0.55))
                                    .frame(height: 0.5)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    private func actualRecordRow(
        _ item: ActualRecordItem,
        showsCategory: Bool = true
    ) -> some View {
        let categoryID = actualCategoryID(item.record)
        return HStack(spacing: 8) {
            Image(systemName: PlanCategory(categoryID: categoryID).systemImage)
                .font(.taption(size: 12, weight: .semibold))
                .foregroundStyle(PlanCategory(categoryID: categoryID).darkColor)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.record.title.isEmpty
                    ? categoryName(categoryID)
                    : item.record.title)
                    .font(.taption(size: 10.5, weight: .semibold))
                    .lineLimit(1)
                Text(
                    (showsCategory ? categoryName(categoryID) + " · " : "")
                        + actualSourceName(item.record.source)
                        + (item.occurrenceCount > 1
                            ? " · \(item.occurrenceCount)회"
                            : "")
                )
                .font(.taption(size: 8.5))
                .foregroundStyle(Color.tpSecondary)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
                Text(durationText(item.totalDuration))
                    .font(.taption(size: 9, weight: .semibold))
                    .foregroundStyle(Color.tpProjectDark)
                Text(actualTimeText(item))
                    .font(.taption(size: 8))
                    .foregroundStyle(Color.tpSecondary)
            }
        }
        .padding(.vertical, 3)
    }

    private var contextCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("\(model.reviewScale.periodName)을 설명한 기록")
                .font(.taption(size: 11, weight: .bold))
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

    private var hierarchySummaryCard: some View {
        let buckets = hierarchySummaryBuckets
        return VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Label(hierarchySummaryTitle, systemImage: "chart.bar.xaxis")
                    .font(.taption(size: 11, weight: .bold))
                Spacer()
                Text("계획 · 실제")
                    .font(.taption(size: 9))
                    .foregroundStyle(Color.tpSecondary)
            }

            if buckets.isEmpty {
                Text("아직 요약할 기록이 없습니다.")
                    .font(.taption(size: 10.5))
                    .foregroundStyle(Color.tpSecondary)
            } else {
                let maximum = max(
                    60,
                    buckets
                        .map { max($0.plannedDuration, $0.actualDuration) }
                        .max() ?? 60
                )
                ForEach(buckets) { bucket in
                    hierarchySummaryRow(bucket, maximum: maximum)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    private func hierarchySummaryRow(
        _ bucket: SummaryBucket,
        maximum: TimeInterval
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Text(hierarchyBucketLabel(bucket))
                    .font(.taption(size: 10, weight: .semibold))
                    .frame(width: 58, alignment: .leading)
                Spacer(minLength: 0)
                Text("계획 \(durationText(bucket.plannedDuration))")
                    .font(.taption(size: 8.5))
                    .foregroundStyle(Color.tpSecondary)
                Text("실제 \(durationText(bucket.actualDuration))")
                    .font(.taption(size: 8.5, weight: .semibold))
                    .foregroundStyle(Color.tpProjectDark)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.tpLine.opacity(0.42))
                    Capsule()
                        .fill(Color.tpProjectDark.opacity(0.32))
                        .frame(width: barWidth(
                            bucket.plannedDuration,
                            maximum: maximum,
                            width: proxy.size.width
                        ))
                    Capsule()
                        .fill(Color.tpProjectDark)
                        .frame(width: barWidth(
                            bucket.actualDuration,
                            maximum: maximum,
                            width: proxy.size.width
                        ))
                }
            }
            .frame(height: 6)
        }
        .padding(.vertical, 3)
    }

    private func barWidth(
        _ duration: TimeInterval,
        maximum: TimeInterval,
        width: CGFloat
    ) -> CGFloat {
        guard maximum > 0 else { return 0 }
        return min(width, width * CGFloat(max(0, duration) / maximum))
    }

    private var hierarchySummaryBuckets: [SummaryBucket] {
        let level: TimelineLevel = switch model.reviewScale {
        case .week: .day
        case .month: .week
        case .year: .month
        }
        return ReviewEngine()
            .aggregation
            .hierarchySummaries(
                for: model.reviewScale.timelineLevel,
                containing: model.selectedDate,
                plans: model.snapshot.plans,
                actuals: model.snapshot.actuals,
                photos: model.snapshot.photos
            )[level] ?? []
    }

    private var hierarchySummaryTitle: String {
        switch model.reviewScale {
        case .week: "이번 주 요일별 요약"
        case .month: "이번 달 주별 요약"
        case .year: "올해 월별 요약"
        }
    }

    private func hierarchyBucketLabel(_ bucket: SummaryBucket) -> String {
        let calendar = Calendar.autoupdatingCurrent
        switch model.reviewScale {
        case .week:
            let weekday = bucket.span.start.formatted(
                .dateTime.weekday(.abbreviated)
            )
            let day = bucket.span.start.formatted(.dateTime.day())
            return "\(weekday) \(day)일"
        case .month:
            let start = bucket.span.start.formatted(.dateTime.month().day())
            let end = bucket.span.end
                .addingTimeInterval(-1)
                .formatted(.dateTime.month().day())
            return "\(start)–\(end)"
        case .year:
            return "\(calendar.component(.month, from: bucket.span.start))월"
        }
    }

    private func contextLine(_ image: String, _ text: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: image)
                .font(.taption(size: 13))
                .foregroundStyle(Color.tpSecondary)
                .frame(width: 14)
            Text(text)
                .font(.taption(size: 10.5))
        }
    }

    private var actualRecordItems: [ActualRecordItem] {
        let now = Date.now
        var seen = Set<UUID>()
        return model.snapshot.actuals
            .compactMap { actual in
                guard seen.insert(actual.id).inserted else { return nil }
                guard let span = actual.span(asOf: now)
                    .intersection(with: report.span) else {
                    return nil
                }
                return ActualRecordItem(
                    id: actual.id.uuidString,
                    record: actual,
                    span: span,
                    totalDuration: span.duration,
                    occurrenceCount: 1,
                    timeRanges: [span]
                )
            }
            .sorted {
                if $0.span.start == $1.span.start {
                    return $0.record.title < $1.record.title
                }
                return $0.span.start < $1.span.start
            }
    }

    private var actualPeriodGroups: [ActualPeriodGroup] {
        let calendar = Calendar.autoupdatingCurrent
        let grouped = Dictionary(grouping: actualRecordItems) {
            actualPeriodStart($0.span.start, calendar: calendar)
        }
        return grouped.keys.sorted().map { start in
            let items = grouped[start, default: []]
            let categories = Dictionary(grouping: items) { actualCategoryID($0.record) }
                .map { id, values in
                    ActualCategoryGroup(
                        id: id,
                        name: categoryName(id),
                        items: mergedItems(values)
                    )
                }
                .sorted { categoryOrder($0.id) == categoryOrder($1.id)
                    ? $0.name < $1.name
                    : categoryOrder($0.id) < categoryOrder($1.id) }
            return ActualPeriodGroup(
                id: start.formatted(.iso8601),
                label: actualPeriodLabel(start, calendar: calendar),
                categories: categories
            )
        }
    }

    private func mergedItems(_ values: [ActualRecordItem]) -> [ActualRecordItem] {
        let grouped = Dictionary(grouping: values) { item in
            let title = item.record.title
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            return "\(actualCategoryID(item.record))|\(title)"
        }
        return grouped.values.compactMap { values in
            guard let first = values.min(by: { $0.span.start < $1.span.start }) else {
                return nil
            }
            let ordered = values.sorted { $0.span.start < $1.span.start }
            let ranges = ordered.flatMap(\.timeRanges)
            return ActualRecordItem(
                id: "merged.\(first.record.id.uuidString)",
                record: first.record,
                span: TimeSpan(
                    start: ranges.map(\.start).min() ?? first.span.start,
                    end: ranges.map(\.end).max() ?? first.span.end
                ),
                totalDuration: ordered.reduce(0) {
                    $0 + $1.totalDuration
                },
                occurrenceCount: ordered.reduce(0) {
                    $0 + $1.occurrenceCount
                },
                timeRanges: ranges
            )
        }
        .sorted { $0.span.start < $1.span.start }
    }

    private func actualTimeText(_ item: ActualRecordItem) -> String {
        guard item.occurrenceCount > 1 else {
            return timeText(item.span)
        }
        let first = item.timeRanges.first.map(timeText) ?? ""
        return first.isEmpty
            ? "합산 \(item.occurrenceCount)회"
            : "\(first) 외"
    }

    private func actualPeriodStart(_ date: Date, calendar: Calendar) -> Date {
        switch model.reviewScale {
        case .week:
            return calendar.startOfDay(for: date)
        case .month:
            return calendar.dateInterval(of: .weekOfYear, for: date)?.start
                ?? calendar.startOfDay(for: date)
        case .year:
            return calendar.dateInterval(of: .month, for: date)?.start
                ?? calendar.startOfDay(for: date)
        }
    }

    private func actualPeriodLabel(_ start: Date, calendar: Calendar) -> String {
        switch model.reviewScale {
        case .week:
            let weekday = calendar.component(.weekday, from: start)
            let names = ["일요일", "월요일", "화요일", "수요일", "목요일", "금요일", "토요일"]
            return "\(names[max(1, min(7, weekday)) - 1]) · \(calendar.component(.month, from: start))월 \(calendar.component(.day, from: start))일"
        case .month:
            let end = calendar.date(byAdding: .day, value: 6, to: start) ?? start
            return "\(start.formatted(.dateTime.month().day()))–\(end.formatted(.dateTime.month().day()))"
        case .year:
            return "\(calendar.component(.month, from: start))월"
        }
    }

    private func categoryOrder(_ id: String) -> Int {
        ["schedule", "location", "movement", "sleep", "activity", "weather", "routine", "action", "photo", "event"]
            .firstIndex(of: id) ?? 99
    }

    private func actualCategoryID(_ actual: ActualRecord) -> String {
        guard actual.categoryID == "activity" else { return actual.categoryID }
        let value = "\(actual.title) \(actual.behavior ?? "")".lowercased()
        if value.contains("수면") { return "sleep" }
        let movementWords = [
            "걷", "달리", "러닝", "자전거", "사이클", "계단", "차량", "자동차",
            "버스", "지하철", "택시", "기차", "비행기", "배", "이동", "walking",
            "running", "cycling", "automotive", "subway", "transit"
        ]
        return movementWords.contains(where: value.contains) ? "movement" : "activity"
    }

    private func actualSourceName(_ source: ActualSource) -> String {
        switch source {
        case .manual: "직접 기록"
        case .timer: "타이머"
        case .healthKit: "Apple 건강"
        case .appleWatch: "Apple Watch 센서"
        case .motion: "iPhone 센서"
        case .calendar: "캘린더"
        case .location: "위치"
        case .photo: "사진"
        case .media: "미디어 재생"
        case .call: "통화"
        }
    }

    private func timeText(_ span: TimeSpan) -> String {
        span.start.formatted(date: .omitted, time: .shortened)
            + "–"
            + span.end.formatted(date: .omitted, time: .shortened)
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
