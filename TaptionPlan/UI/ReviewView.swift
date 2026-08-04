import Charts
import SwiftUI

/// 화면 본문에서 계산하면 스크롤·제스처마다 기간 전체를 다시 훑게 된다.
/// 데이터·배율·기준일이 바뀔 때 한 번만 만들어 두고 그대로 그린다.
private struct ReviewContent: Equatable {
    var span: TimeSpan
    var plannedCategories: [CategoryDuration]
    var contexts: [ReviewContext]
    var groups: [RecordCategoryGroup]
    var rings: [RecordClockRing]
    var buckets: [RecordChartBucket]

    static let empty = ReviewContent(
        span: TimeSpan(start: .now, end: .now),
        plannedCategories: [],
        contexts: [],
        groups: [],
        rings: [],
        buckets: []
    )
}

private struct ReviewContentKey: Equatable {
    let revision: UInt64
    let scale: TimeScale
    let date: Date
}

struct ReviewView: View {
    @Bindable var model: AppModel

    @State private var content = ReviewContent.empty
    @State private var collapsedGroupIDs: Set<String> = []
    @State private var highlightedCategoryID: String?

    var body: some View {
        VStack(spacing: 0) {
            reviewHeader

            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 10) {
                        chartCard
                        planBreakdownCard
                        recordHierarchyCard
                        contextCard
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                    // 하단 탭 막대 뒤로 마지막 줄이 숨지 않게 비워 둔다.
                    .padding(.bottom, DraftBottomBarMetrics.contentInset)
                }
                .background(Color.tpBackground)
                .onChange(of: highlightedCategoryID) { _, categoryID in
                    guard let categoryID else { return }
                    withAnimation(.easeInOut(duration: 0.22)) {
                        proxy.scrollTo(anchorID(categoryID), anchor: .top)
                    }
                }
            }
        }
        .task(id: contentKey) { rebuildContent() }
    }

    // MARK: - 머리말

    private var reviewHeader: some View {
        VStack(spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text("기록")
                    .font(.taption(size: 19, weight: .bold))
                Spacer()
                Text(periodText(content.span))
                    .font(.taption(size: 12))
                    .foregroundStyle(Color.tpSecondary)
            }

            HStack(spacing: 0) {
                ForEach(TimeScale.allCases) { scale in
                    Button {
                        model.reviewScale = scale
                    } label: {
                        Text(scale.rawValue)
                            .font(
                                .taption(
                                    size: 12.5,
                                    weight: model.reviewScale == scale
                                        ? .semibold
                                        : .regular
                                )
                            )
                            .foregroundStyle(
                                model.reviewScale == scale
                                    ? Color.tpInk
                                    : Color.tpSecondary
                            )
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                            .background {
                                if model.reviewScale == scale {
                                    RoundedRectangle(cornerRadius: 7)
                                        .fill(.white)
                                        .shadow(
                                            color: .black.opacity(0.12),
                                            radius: 1.5,
                                            y: 1
                                        )
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

    // MARK: - 그림

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Label(chartTitle, systemImage: chartSymbol)
                    .font(.taption(size: 11, weight: .bold))
                Spacer()
                Text(DurationText.korean(recordedDuration))
                    .font(.taption(size: 9))
                    .foregroundStyle(Color.tpSecondary)
            }

            if content.groups.isEmpty {
                Text("이 기간에 저장된 실제 데이터가 없습니다.")
                    .font(.taption(size: 10.5))
                    .foregroundStyle(Color.tpSecondary)
            } else {
                if model.reviewScale == .day {
                    dayClockChart
                } else {
                    barChart
                }
                categoryLegend
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(
            Color.white,
            in: RoundedRectangle(cornerRadius: 13, style: .continuous)
        )
    }

    private var chartTitle: String {
        switch model.reviewScale {
        case .day: "하루 24시간"
        case .week: "요일별 기록"
        case .month: "날짜별 기록"
        case .year: "월별 기록"
        }
    }

    private var chartSymbol: String {
        model.reviewScale == .day ? "clock" : "chart.bar.xaxis"
    }

    private var recordedDuration: TimeInterval {
        content.groups.reduce(0) { $0 + $1.duration }
    }

    /// 24시간 원형 시간표. 자정이 12시 방향이고 시계 방향으로 하루가 흐른다.
    /// 카테고리마다 고리를 하나씩 만들어 같은 시각에 겹친 기록이 서로를
    /// 가리지 않게 한다. 바깥 고리가 총 시간이 긴 카테고리다.
    private var dayClockChart: some View {
        let rings = Array(content.rings.prefix(6))
        return GeometryReader { proxy in
            Canvas { context, size in
            let side = min(size.width, size.height)
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            // 시각 숫자가 캔버스 밖으로 잘리지 않도록 가장자리를 비워 둔다.
            let outer = side / 2 - 24
            drawClockFace(context: context, center: center, radius: outer + 9)

            for (index, ring) in rings.enumerated() {
                let radius = outer - CGFloat(index) * 13
                guard radius > 16 else { break }
                let tint = color(forCategoryID: ring.categoryID)
                let isDimmed = highlightedCategoryID != nil
                    && highlightedCategoryID != ring.categoryID
                context.stroke(
                    Path {
                        $0.addArc(
                            center: center,
                            radius: radius,
                            startAngle: .degrees(0),
                            endAngle: .degrees(360),
                            clockwise: false
                        )
                    },
                    with: .color(tint.opacity(0.12)),
                    lineWidth: 9
                )
                for arc in ring.arcs {
                    context.stroke(
                        Path {
                            $0.addArc(
                                center: center,
                                radius: radius,
                                startAngle: clockAngle(arc.startFraction),
                                endAngle: clockAngle(
                                    max(
                                        arc.endFraction,
                                        arc.startFraction + 0.0018
                                    )
                                ),
                                clockwise: false
                            )
                        },
                        with: .color(tint.opacity(isDimmed ? 0.22 : 1)),
                        style: StrokeStyle(lineWidth: 9, lineCap: .butt)
                    )
                }
            }
            }
            .contentShape(Rectangle())
            .onTapGesture { point in
                highlightedCategoryID = ringCategory(
                    at: point,
                    in: proxy.size,
                    rings: rings
                )
            }
        }
        .frame(height: 226)
        .accessibilityLabel("하루 24시간 원형 기록")
    }

    private func drawClockFace(
        context: GraphicsContext,
        center: CGPoint,
        radius: CGFloat
    ) {
        for hour in 0..<24 {
            let angle = clockAngle(Double(hour) / 24)
            let isMajor = hour % 6 == 0
            let length: CGFloat = isMajor ? 6 : 3
            let start = point(center: center, radius: radius - length, angle: angle)
            let end = point(center: center, radius: radius, angle: angle)
            context.stroke(
                Path { path in
                    path.move(to: start)
                    path.addLine(to: end)
                },
                with: .color(Color.tpSecondary.opacity(isMajor ? 0.55 : 0.22)),
                lineWidth: isMajor ? 1.2 : 0.8
            )
            if isMajor {
                let label = context.resolve(
                    Text("\(hour)")
                        .font(.taption(size: 8, weight: .bold))
                        .foregroundStyle(Color.tpSecondary)
                )
                context.draw(
                    label,
                    at: point(center: center, radius: radius + 7, angle: angle)
                )
            }
        }
    }

    private func clockAngle(_ fraction: Double) -> Angle {
        .degrees(fraction * 360 - 90)
    }

    private func point(
        center: CGPoint,
        radius: CGFloat,
        angle: Angle
    ) -> CGPoint {
        CGPoint(
            x: center.x + radius * cos(angle.radians),
            y: center.y + radius * sin(angle.radians)
        )
    }

    /// 바깥에서 안쪽으로 13pt 간격의 고리다. 누른 지점의 반지름으로 몇 번째
    /// 고리인지 되짚어 해당 카테고리를 아래 목록에서 강조한다.
    private func ringCategory(
        at point: CGPoint,
        in size: CGSize,
        rings: [RecordClockRing]
    ) -> String? {
        let side = min(size.width, size.height)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let outer = side / 2 - 24
        let distance = hypot(point.x - center.x, point.y - center.y)
        guard distance <= outer + 5 else { return nil }
        let index = Int(((outer + 4.5) - distance) / 13)
        guard index >= 0, index < rings.count else { return nil }
        let categoryID = rings[index].categoryID
        return highlightedCategoryID == categoryID ? nil : categoryID
    }

    private var barChart: some View {
        Chart {
            ForEach(content.buckets) { bucket in
                ForEach(bucket.slices) { slice in
                    BarMark(
                        x: .value("구간", bucket.span.start, unit: barUnit),
                        y: .value("시간", slice.duration / 3_600)
                    )
                    .foregroundStyle(
                        color(forCategoryID: slice.categoryID)
                            .opacity(
                                highlightedCategoryID == nil
                                    || highlightedCategoryID == slice.categoryID
                                    ? 1
                                    : 0.2
                            )
                    )
                }
            }
        }
        // 기록이 없는 날도 칸을 차지해야 요일·날짜가 전부 보인다.
        .chartXScale(domain: content.span.start...content.span.end)
        .chartXAxis {
            AxisMarks(values: .stride(by: barUnit, count: barLabelStride)) {
                value in
                AxisGridLine().foregroundStyle(Color.tpLine.opacity(0.5))
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(barLabel(date))
                            .font(.taption(size: 8))
                            .foregroundStyle(Color.tpSecondary)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) {
                value in
                AxisGridLine().foregroundStyle(Color.tpLine.opacity(0.5))
                AxisValueLabel {
                    if let hours = value.as(Double.self) {
                        Text("\(Int(hours))h")
                            .font(.taption(size: 8))
                            .foregroundStyle(Color.tpSecondary)
                    }
                }
            }
        }
        .frame(height: 168)
    }

    private var barUnit: Calendar.Component {
        model.reviewScale == .year ? .month : .day
    }

    private var barLabelStride: Int {
        switch model.reviewScale {
        case .month: 5
        case .year: 2
        default: 1
        }
    }

    private func barLabel(_ date: Date) -> String {
        let calendar = Calendar.autoupdatingCurrent
        switch model.reviewScale {
        case .year:
            return "\(calendar.component(.month, from: date))월"
        case .month:
            return "\(calendar.component(.day, from: date))"
        default:
            let names = ["일", "월", "화", "수", "목", "금", "토"]
            return names[
                max(1, min(7, calendar.component(.weekday, from: date))) - 1
            ]
        }
    }

    private var categoryLegend: some View {
        ChipFlowLayout(spacing: 5) {
            ForEach(content.groups.prefix(8)) { group in
                Button {
                    highlightedCategoryID =
                        highlightedCategoryID == group.id ? nil : group.id
                } label: {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(color(forCategoryID: group.id))
                            .frame(width: 7, height: 7)
                        Text(group.name)
                            .font(
                                .taption(
                                    size: 9,
                                    weight: highlightedCategoryID == group.id
                                        ? .bold
                                        : .regular
                                )
                            )
                            .foregroundStyle(Color.tpInk)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        highlightedCategoryID == group.id
                            ? color(forCategoryID: group.id).opacity(0.16)
                            : Color(red: 0.95, green: 0.95, blue: 0.96),
                        in: Capsule()
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - 계획

    private var planBreakdownCard: some View {
        let plannedCategories = content.plannedCategories
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
                        Text("계획 \(DurationText.korean(category.planned))")
                            .font(.taption(size: 9))
                            .foregroundStyle(Color.tpSecondary)
                        if category.actual > 0 {
                            Text("실제 \(DurationText.korean(category.actual))")
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
        .background(
            Color.white,
            in: RoundedRectangle(cornerRadius: 13, style: .continuous)
        )
    }

    // MARK: - 계층형 기록

    private var recordHierarchyCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Label("실제 기록", systemImage: "checkmark.circle")
                    .font(.taption(size: 11, weight: .bold))
                Spacer()
                Text("\(childCount)개 항목")
                    .font(.taption(size: 9))
                    .foregroundStyle(Color.tpSecondary)
            }

            if content.groups.isEmpty {
                Text("이 기간에 저장된 실제 데이터가 없습니다.")
                    .font(.taption(size: 10.5))
                    .foregroundStyle(Color.tpSecondary)
            } else {
                ForEach(content.groups) { group in
                    categorySection(group)
                        .id(anchorID(group.id))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(
            Color.white,
            in: RoundedRectangle(cornerRadius: 13, style: .continuous)
        )
    }

    private var childCount: Int {
        content.groups.reduce(0) { $0 + $1.children.count }
    }

    @ViewBuilder
    private func categorySection(_ group: RecordCategoryGroup) -> some View {
        let isExpanded = !collapsedGroupIDs.contains(group.id)
        VStack(alignment: .leading, spacing: 2) {
            Button {
                if isExpanded {
                    collapsedGroupIDs.insert(group.id)
                } else {
                    collapsedGroupIDs.remove(group.id)
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.down")
                        .font(.taption(size: 8, weight: .bold))
                        .foregroundStyle(Color.tpSecondary)
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                        .frame(width: 10)
                    Image(systemName: symbolName(group))
                        .font(.taption(size: 11, weight: .semibold))
                        .foregroundStyle(color(forCategoryID: group.id))
                        .frame(width: 15)
                    Text(group.name)
                        .font(.taption(size: 11, weight: .bold))
                        .foregroundStyle(Color.tpInk)
                    Spacer(minLength: 4)
                    Text(groupTotalText(group))
                        .font(.taption(size: 10, weight: .semibold))
                        .foregroundStyle(color(forCategoryID: group.id))
                }
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(
                highlightedCategoryID == group.id
                    ? color(forCategoryID: group.id).opacity(0.09)
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: 7)
            )

            if isExpanded {
                ForEach(group.children) { child in
                    childRow(child, in: group)
                }
            }
        }
        .animation(.easeInOut(duration: 0.18), value: isExpanded)
    }

    private func childRow(
        _ child: RecordGroupChild,
        in group: RecordCategoryGroup
    ) -> some View {
        Button {
            model.detail = .actual(child.recordID)
        } label: {
            HStack(spacing: 7) {
                Text(child.title)
                    .font(.taption(size: 10, weight: .medium))
                    .lineLimit(1)
                if child.occurrenceCount > 1 {
                    Text("\(child.occurrenceCount)회")
                        .font(.taption(size: 8))
                        .foregroundStyle(Color.tpSecondary)
                }
                Spacer(minLength: 4)
                Text(
                    child.start.formatted(date: .omitted, time: .shortened)
                )
                .font(.taption(size: 8))
                .foregroundStyle(Color.tpSecondary)
                Text(DurationText.korean(child.duration))
                    .font(.taption(size: 9, weight: .semibold))
                    .foregroundStyle(Color.tpSecondary)
                    .frame(minWidth: 52, alignment: .trailing)
                Image(systemName: "chevron.right")
                    .font(.taption(size: 7, weight: .bold))
                    .foregroundStyle(Color.tpSecondary.opacity(0.7))
            }
            .padding(.leading, 31)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "\(group.name) \(child.title) \(DurationText.korean(child.duration))"
        )
    }

    private func groupTotalText(_ group: RecordCategoryGroup) -> String {
        let total = DurationText.korean(group.duration)
        guard group.id == "movement",
              let dominant = group.dominantChildTitle,
              group.children.count > 1 else {
            return total
        }
        return "\(total) · \(dominant)"
    }

    // MARK: - 맥락

    private var contextCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("이 기간을 설명한 기록")
                .font(.taption(size: 11, weight: .bold))
            if content.contexts.isEmpty {
                contextLine(
                    "tray",
                    "사진·날씨·메모가 연결되면 이번 기간의 맥락을 보여드립니다."
                )
            } else {
                ForEach(content.contexts) { context in
                    contextLine(context.symbolName, context.text)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(
            Color.white,
            in: RoundedRectangle(cornerRadius: 13, style: .continuous)
        )
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

    // MARK: - 데이터

    private var contentKey: ReviewContentKey {
        ReviewContentKey(
            revision: model.timelineRevision,
            scale: model.reviewScale,
            date: model.selectedDate
        )
    }

    private func rebuildContent() {
        let engine = ReviewEngine()
        let report = engine.report(
            for: model.reviewScale.timelineLevel,
            containing: model.selectedDate,
            plans: model.snapshot.plans,
            actuals: model.snapshot.actuals,
            weather: model.snapshot.weather,
            photos: model.snapshot.photos,
            memos: model.snapshot.memos
        )
        let actuals = model.snapshot.actuals
        let span = report.span

        var rings: [RecordClockRing] = []
        var buckets: [RecordChartBucket] = []
        if model.reviewScale == .day {
            rings = RecordChartEngine.clockRings(actuals: actuals, in: span)
        } else {
            buckets = RecordChartEngine.buckets(
                actuals: actuals,
                in: span,
                unit: model.reviewScale == .year ? .month : .day,
                calendar: engine.aggregation.calendar
            )
        }

        content = ReviewContent(
            span: span,
            plannedCategories: report.categories,
            contexts: report.contexts,
            groups: ActualRecordGroupingEngine.groups(
                actuals: actuals,
                in: span,
                categories: model.snapshot.categories
            ),
            rings: rings,
            buckets: buckets
        )
        collapsedGroupIDs = collapsedGroupIDs.intersection(
            Set(content.groups.map(\.id))
        )
        if let highlighted = highlightedCategoryID,
           !content.groups.contains(where: { $0.id == highlighted }) {
            highlightedCategoryID = nil
        }
    }

    // MARK: - 표기

    private func anchorID(_ categoryID: String) -> String {
        "record.group.\(categoryID)"
    }

    private func periodText(_ span: TimeSpan) -> String {
        span.start.formatted(.dateTime.month().day())
            + " – "
            + span.end.addingTimeInterval(-1).formatted(.dateTime.month().day())
    }

    private func categoryName(_ id: String) -> String {
        model.snapshot.categories.first { $0.id == id }?.name
            ?? TimelineRowKind.title(forCategoryID: id)
            ?? PlanCategory(categoryID: id).rawValue
    }

    private func symbolName(_ group: RecordCategoryGroup) -> String {
        TimelineRowKind(categoryID: group.id)?.systemImage
            ?? group.icon?.systemImage
            ?? PlanCategory(categoryID: group.id).systemImage
    }

    private func color(forCategoryID id: String) -> Color {
        if let hex = content.groups.first(where: { $0.id == id })?.colorHex {
            return Color(hex: hex)
        }
        switch id {
        case TimelineRowKind.appUsage.rawValue: return .tpProjectDark
        case TimelineRowKind.weather.rawValue: return .tpWeatherDark
        case TimelineRowKind.calendar.rawValue:
            return Color(red: 0.56, green: 0.56, blue: 0.58)
        default: return PlanCategory(categoryID: id).darkColor
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
        ActualRecordCategoryResolver.categoryID(for: record)
    }

    private func symbolName(
        _ record: ActualRecord,
        categoryID: String
    ) -> String {
        if categoryID == "movement" {
            return MovementPresentation.symbol(for: record)
        }
        return TimelineRowKind(categoryID: categoryID)?.systemImage
            ?? PlanCategory(categoryID: categoryID).systemImage
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
        if let title = TimelineRowKind.title(forCategoryID: id) { return title }
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
        DurationText.korean(interval)
    }
}


#Preview {
    ReviewView(model: AppModel())
}
