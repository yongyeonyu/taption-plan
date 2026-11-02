import Charts
import SwiftUI

extension ReviewView {
    var barChart: some View {
        Chart {
            ForEach(content.chartBuckets) { bucket in
                ForEach(bucket.slices) { slice in
                    BarMark(
                        x: .value("구간", bucket.span.start, unit: barUnit),
                        y: .value("시간", slice.duration / 3_600)
                    )
                    .foregroundStyle(
                        detailColor(.dayPhase, token: slice.categoryID)
                            .opacity(barOpacity(bucket, slice))
                    )
                }
            }
        }
        // 기록이 없는 날도 칸을 차지해야 요일·날짜가 전부 보인다.
        .chartXScale(domain: content.period.start...content.period.end)
        .chartYScale(domain: 0...barMaximumHours)
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
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .gesture(
                        SpatialTapGesture().onEnded { value in
                            selectChartBucket(
                                at: value.location,
                                proxy: proxy,
                                geometry: geometry
                            )
                        }
                    )
            }
        }
        .frame(height: 168)
        .accessibilityHint("막대를 눌러 해당 구간의 상세 기록 보기")
    }

    func selectChartBucket(
        at location: CGPoint,
        proxy: ChartProxy,
        geometry: GeometryProxy
    ) {
        clearClockHighlight()
        guard let plotFrame = proxy.plotFrame else { return }
        let frame = geometry[plotFrame]
        guard frame.contains(location),
              let date = proxy.value(
                  atX: location.x - frame.minX,
                  as: Date.self
              ),
              let bucket = content.chartBuckets.first(where: {
                  $0.total > 0
                      && $0.span.start <= date
                      && date < $0.span.end
              }) else {
            return
        }
        selectedBucketIDs = []
        selectedChartBucketID = selectedChartBucketID == bucket.id
            ? nil
            : bucket.id
    }

    /// 고른 칸 밖의 막대는 남겨 두되 흐리게 죽인다. 합계·목록이 세지 않은
    /// 시간이 눈에는 그대로 보이면 두 값이 어긋나 보이기 때문이다.
    func barOpacity(
        _ bucket: RecordChartBucket,
        _ slice: RecordChartSlice
    ) -> Double {
        if !content.selectedChartBucketIDs.isEmpty,
           !content.selectedChartBucketIDs.contains(bucket.id) {
            return 0.14
        }
        guard let highlightedCategoryID else { return 1 }
        return highlightedCategoryID == slice.categoryID ? 1 : 0.2
    }

    var barUnit: Calendar.Component {
        model.reviewScale == .year ? .month : .day
    }

    var barMaximumHours: Double {
        switch model.reviewScale {
        case .week, .month: 24
        case .year: RecordChartEngine.maxTotalHours(content.chartBuckets)
        case .day: 24
        }
    }

    var barLabelStride: Int {
        switch model.reviewScale {
        case .month: 5
        case .year: 2
        default: 1
        }
    }

    func barLabel(_ date: Date) -> String {
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

    var categoryLegend: some View {
        ChipFlowLayout(spacing: TaptionSpacing.compact) {
            if model.reviewScale == .day {
                Text("상세활동")
                    .font(.taption(size: 8.5, weight: .bold))
                    .foregroundStyle(Color.tpSecondary)
                    .padding(.vertical, 4)
                ForEach(content.groups.prefix(8)) { group in
                    if let kind = activityDetailKind(for: group.id),
                       !activityTokens(for: kind).isEmpty {
                        ForEach(activityTokens(for: kind), id: \.self) { token in
                            activityDetailLegendChip(kind, token: token)
                        }
                    } else {
                        categoryLegendChip(group)
                    }
                }
            } else {
                Text("일과")
                    .font(.taption(size: 8.5, weight: .bold))
                    .foregroundStyle(Color.tpSecondary)
                    .padding(.vertical, 4)
                ForEach(content.phaseDurations.prefix(12)) { value in
                    phaseSummaryLegendChip(value.categoryID)
                }
            }
        }
    }

    func activityDetailKind(
        for categoryID: String
    ) -> RecordClockDetailKind? {
        switch categoryID {
        case TimelineRowKind.sleep.rawValue: .sleepStage
        case TimelineRowKind.movement.rawValue: .travel
        default: nil
        }
    }

    func activityTokens(
        for kind: RecordClockDetailKind
    ) -> [String] {
        content.activityRings
            .filter { $0.kind == kind }
            .flatMap(detailTokens)
    }

    func categoryLegendChip(_ group: RecordCategoryGroup) -> some View {
        let isSelected = highlightedCategoryID == group.id
        return Button {
            let next = ReviewClockHighlight.category(group.id)
            clockHighlight = clockHighlight == next ? nil : next
        } label: {
            HStack(spacing: TaptionSpacing.tight) {
                Circle()
                    .fill(color(forCategoryID: group.id))
                    .frame(width: 7, height: 7)
                Text(group.name)
                    .font(
                        .taption(
                            size: 9,
                            weight: isSelected
                                ? .bold
                                : .regular
                        )
                    )
                    .foregroundStyle(Color.tpInk)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                isSelected
                    ? color(forCategoryID: group.id).opacity(0.16)
                    : Color.tpSky.opacity(0.12),
                in: Capsule()
            )
        }
        .opacity(legendOpacity(isSelected: isSelected))
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    func activityDetailLegendChip(
        _ kind: RecordClockDetailKind,
        token: String
    ) -> some View {
        let selection = ReviewDetailSelection(kind: kind, token: token)
        let isSelected = highlightedDetail == selection
        return Button {
            let next = ReviewClockHighlight.detail(selection)
            clockHighlight = clockHighlight == next ? nil : next
        } label: {
            HStack(spacing: TaptionSpacing.tight) {
                Circle()
                    .fill(detailColor(kind, token: token))
                    .frame(width: 7, height: 7)
                Text(detailName(kind, token: token))
                    .font(
                        .taption(
                            size: 9,
                            weight: isSelected
                                ? .bold
                                : .regular
                        )
                    )
                    .foregroundStyle(Color.tpInk)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                isSelected
                    ? detailColor(kind, token: token).opacity(0.16)
                    : Color.tpSky.opacity(0.12),
                in: Capsule()
            )
        }
        .opacity(legendOpacity(isSelected: isSelected))
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    func phaseSummaryLegendChip(_ id: String) -> some View {
        let phase = DayPhase(rawValue: id)
        let tint = detailColor(.dayPhase, token: id)
        let isSelected = highlightedCategoryID == id
        return Button {
            let next = ReviewClockHighlight.category(id)
            clockHighlight = clockHighlight == next ? nil : next
        } label: {
            HStack(spacing: TaptionSpacing.tight) {
                Circle().fill(tint).frame(width: 7, height: 7)
                Text(phase?.title ?? id)
                    .font(
                        .taption(
                            size: 9,
                            weight: isSelected
                                ? .bold
                                : .regular
                        )
                    )
                    .foregroundStyle(Color.tpInk)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                isSelected
                    ? tint.opacity(0.16)
                    : Color.tpControlFillSoft,
                in: Capsule()
            )
        }
        .opacity(legendOpacity(isSelected: isSelected))
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    func legendOpacity(isSelected: Bool) -> Double {
        clockHighlight == nil || isSelected ? 1 : 0.42
    }
}
