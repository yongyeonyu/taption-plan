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
        return Button {
            model.detail = .actual(item.record.id)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: categoryID == "movement"
                    ? MovementPresentation.symbol(for: item.record)
                    : PlanCategory(categoryID: categoryID).systemImage)
                    .font(.taption(size: 12, weight: .semibold))
                    .foregroundStyle(categoryID == "movement"
                        ? Color.tpTransitDark
                        : PlanCategory(categoryID: categoryID).darkColor)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayTitle(item.record, categoryID: categoryID))
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
                Image(systemName: "chevron.right")
                    .font(.taption(size: 8, weight: .bold))
                    .foregroundStyle(Color.tpSecondary.opacity(0.7))
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
        let asOf = min(Date.now, report.span.end)
        var seen = Set<UUID>()
        return model.snapshot.actuals
            .compactMap { actual in
                guard seen.insert(actual.id).inserted else { return nil }
                guard actual.startedAt < asOf,
                      let span = actual.span(asOf: asOf)
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
            let categoryID = actualCategoryID(item.record)
            let title = displayTitle(item.record, categoryID: categoryID)
                .lowercased()
            return "\(categoryID)|\(title)"
        }
        return grouped.values.compactMap { values in
            guard let first = values.min(by: { $0.span.start < $1.span.start }) else {
                return nil
            }
            let ordered = values.sorted { $0.span.start < $1.span.start }
            let ranges = ActualIntervalMergeEngine.union(
                ordered.flatMap(\.timeRanges)
            )
            guard let firstRange = ranges.first,
                  let lastRange = ranges.last else {
                return nil
            }
            return ActualRecordItem(
                id: "merged.\(first.record.id.uuidString)",
                record: first.record,
                span: TimeSpan(
                    start: firstRange.start,
                    end: lastRange.end
                ),
                totalDuration: ActualIntervalMergeEngine.duration(
                    of: ordered.flatMap(\.timeRanges)
                ),
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
        case .appUsage: "앱 사용시간"
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

    private func displayTitle(
        _ record: ActualRecord,
        categoryID: String
    ) -> String {
        if categoryID == "movement" {
            return MovementPresentation.title(for: record)
        }
        return record.title.isEmpty ? categoryName(categoryID) : record.title
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

struct ActualRecordDetailView: View {
    @Bindable var model: AppModel
    let recordID: UUID

    private var record: ActualRecord? {
        model.snapshot.actuals.first { $0.id == recordID }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    model.detail = nil
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.taption(size: 18, weight: .semibold))
                }
                .buttonStyle(.plain)
                Text("기록 상세")
                    .font(.taption(size: 19, weight: .bold))
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(Color.white)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color.tpLine).frame(height: 0.5)
            }

            ScrollView(showsIndicators: false) {
                if let record {
                    detailContent(record)
                        .padding(14)
                } else {
                    ContentUnavailableView(
                        "기록을 찾을 수 없습니다",
                        systemImage: "clock.badge.exclamationmark",
                        description: Text("저장된 자동 기록이 변경되었을 수 있습니다.")
                    )
                    .padding(24)
                }
            }
            .background(Color.tpBackground)
        }
    }

    private func detailContent(_ record: ActualRecord) -> some View {
        let categoryID = displayCategoryID(record)
        let span = record.span(asOf: Date.now)
        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Label(
                    displayTitle(record, categoryID: categoryID),
                    systemImage: symbolName(record, categoryID: categoryID)
                )
                .font(.taption(size: 17, weight: .bold))
                .foregroundStyle(PlanCategory(categoryID: categoryID).darkColor)
                applicationNameLabel(record)
                Text("\(span.start.formatted(date: .abbreviated, time: .shortened)) – \(span.end.formatted(date: .omitted, time: .shortened))")
                    .font(.taption(size: 11))
                    .foregroundStyle(Color.tpSecondary)
                Text(durationText(span.duration))
                    .font(.taption(size: 15, weight: .semibold))
                    .foregroundStyle(Color.tpProjectDark)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 15))

            detailRow("데이터 출처", sourceName(record.source))
            detailRow("신뢰도", record.confidence.rawValue)
            let related = relatedRecords(for: record)
            if related.count > 1 {
                let total = ActualIntervalMergeEngine.duration(
                    of: related.map { $0.span(asOf: Date.now) }
                )
                detailRow("같은 날 합산", "\(durationText(total)) · \(related.count)회")
            }
            if let behavior = record.behavior, !behavior.isEmpty {
                detailRow("행동 분류", behavior)
            }
            if !record.evidence.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("측정 근거")
                        .font(.taption(size: 10, weight: .bold))
                    ForEach(record.evidence, id: \.self) { evidence in
                        Text("· \(evidence)")
                            .font(.taption(size: 10))
                            .foregroundStyle(Color.tpSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 13))
            }
            if AutomaticRecordTimelineEngine.isImmutable(record) {
                Label("센서·건강 데이터는 원본 보존을 위해 수정할 수 없습니다.", systemImage: "lock.fill")
                    .font(.taption(size: 9))
                    .foregroundStyle(Color.tpSecondary)
                    .padding(.horizontal, 2)
            }
        }
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .font(.taption(size: 10, weight: .semibold))
            Spacer()
            Text(value)
                .font(.taption(size: 10))
                .foregroundStyle(Color.tpSecondary)
        }
        .padding(12)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
    }

    private func applicationNameLabel(_ record: ActualRecord) -> some View {
        AppUsageNameLabel(
            record: record,
            tokenIndex: model.appUsageTokenIndex
        )
    }

    private func displayCategoryID(_ record: ActualRecord) -> String {
        guard record.categoryID == "activity" else { return record.categoryID }
        let value = "\(record.title) \(record.behavior ?? "")".lowercased()
        if value.contains("수면") || value.contains("sleep") { return "sleep" }
        let movementWords = [
            "걷", "달리", "차량", "자동차", "자전거", "버스", "지하철",
            "walking", "running", "cycling", "automotive",
        ]
        return movementWords.contains(where: value.contains) ? "movement" : "activity"
    }

    private func symbolName(
        _ record: ActualRecord,
        categoryID: String
    ) -> String {
        switch categoryID {
        case "movement": MovementPresentation.symbol(for: record)
        case "appUsage": "app.badge.clock"
        default: PlanCategory(categoryID: categoryID).systemImage
        }
    }

    private func displayTitle(
        _ record: ActualRecord,
        categoryID: String
    ) -> String {
        if categoryID == "movement" {
            return MovementPresentation.title(for: record)
        }
        return record.title.isEmpty ? categoryName(categoryID) : record.title
    }

    private func categoryName(_ id: String) -> String {
        if id == "appUsage" { return ScreenTimeUsageRecordEngine.laneTitle }
        return model.snapshot.categories.first { $0.id == id }?.name
            ?? PlanCategory(categoryID: id).rawValue
    }

    private func relatedRecords(for record: ActualRecord) -> [ActualRecord] {
        let calendar = Calendar.autoupdatingCurrent
        return model.snapshot.actuals.filter { candidate in
            candidate.categoryID == record.categoryID
                && candidate.title == record.title
                && calendar.isDate(
                    candidate.startedAt,
                    inSameDayAs: record.startedAt
                )
        }
    }

    private func sourceName(_ source: ActualSource) -> String {
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
        case .appUsage: "앱 사용시간"
        }
    }

    private func durationText(_ interval: TimeInterval) -> String {
        let minutes = max(0, Int(interval / 60))
        let hours = minutes / 60
        let remainder = minutes % 60
        if hours == 0 { return "\(remainder)분" }
        if remainder == 0 { return "\(hours)시간" }
        return "\(hours)시간 \(remainder)분"
    }
}

#Preview {
    ReviewView(model: AppModel())
}
