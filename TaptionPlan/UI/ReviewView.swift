import Charts
import SwiftUI

/// 화면 본문에서 계산하면 스크롤·제스처마다 기간 전체를 다시 훑게 된다.
/// 데이터·배율·기준일이 바뀔 때 한 번만 만들어 두고 그대로 그린다.
private struct ReviewContent: Equatable {
    /// 배율이 정한 기간 전체. 막대의 가로 범위와 옆으로 넘기기가 이 값을 쓴다.
    var period: TimeSpan
    /// 합계·눈금판·목록이 함께 읽는 단 하나의 구간 묶음. 고른 칸이 없으면
    /// `[period]` 하나뿐이라 지금까지의 화면과 똑같다.
    var spans: [TimeSpan]
    /// 손가락으로 켜고 끌 수 있는 칸. 하루 배율에서는 비어 있다.
    var pickableBuckets: [ReviewPeriodBucket]
    var selectedBucketCount: Int
    var plannedCategories: [CategoryDuration]
    var contexts: [ReviewContext]
    var groups: [RecordCategoryGroup]
    /// 링과 목록에 실제로 그린 파생 기록. 탭 대상도 같은 배열에서 찾는다.
    var displayActuals: [ActualRecord]
    /// 하루 기록 목록은 일과를 먼저 보여 주고 그 안에 활동을 넣는다.
    var phaseGroups: [RecordCategoryGroup]
    var rings: [RecordClockRing]
    /// 가장 바깥의 일과 고리. 하루 배율에서만 만들어진다.
    var phaseRing: RecordClockDetailRing?
    /// 수면 단계와 이동수단은 별도 상세 고리 없이 활동 띠 위에 그린다.
    var activityRings: [RecordClockDetailRing]
    /// 날씨·위치는 상세 고리와 분리해 환경 정보로 표시한다.
    var contextRings: [RecordClockDetailRing]
    /// 일별 일과를 합산한 값. 주·월·년 막대와 범례가 이 값만 읽는다.
    var phaseDurations: [CategoryDuration]
    var chartBuckets: [RecordChartBucket]
    /// 고른 구간에 걸친 막대. 비어 있으면 모두 고른 것과 같다.
    var selectedChartBucketIDs: Set<String>

    static let empty = ReviewContent(
        period: TimeSpan(start: .now, end: .now),
        spans: [],
        pickableBuckets: [],
        selectedBucketCount: 0,
        plannedCategories: [],
        contexts: [],
        groups: [],
        displayActuals: [],
        phaseGroups: [],
        rings: [],
        phaseRing: nil,
        activityRings: [],
        contextRings: [],
        phaseDurations: [],
        chartBuckets: [],
        selectedChartBucketIDs: []
    )
}

/// 눈금판을 깨우는 간격. 재생 중에는 화면 갱신 예산인 60Hz까지만 올리고,
/// 멈춰 있을 때는 현재 시각 바늘이 흐르도록 분마다 한 번만 깨운다.
private struct RecordClockSchedule: TimelineSchedule {
    var isPlaying: Bool

    func entries(
        from startDate: Date,
        mode: TimelineScheduleMode
    ) -> AnyIterator<Date> {
        let step = isPlaying ? RecordClockEngine.frameInterval : 60
        var next = startDate
        return AnyIterator {
            defer { next = next.addingTimeInterval(step) }
            return next
        }
    }
}

private struct ReviewContentKey: Equatable {
    let revision: UInt64
    let scale: TimeScale
    let date: Date
    let selectedBucketIDs: Set<String>
    let selectedChartBucketID: String?
    let healthRefreshedAt: Date?
}

private struct ReviewDetailSelection: Equatable {
    var kind: RecordClockDetailKind
    var token: String
}

private enum ReviewClockHighlight: Equatable {
    case phase(arcID: String, token: String)
    case category(String)
    case detail(ReviewDetailSelection)
}

private struct PlaybackContextReadout {
    var weatherToken: String?
    var locationToken: String?

    var isEmpty: Bool {
        weatherToken == nil && locationToken == nil
    }
}

private struct LinearClockItem {
    var title: String
    var tint: Color
}

enum CircularActivityLabelQuadrant: CaseIterable, Hashable {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight

    init(clockFraction: Double) {
        guard clockFraction.isFinite else {
            self = .topRight
            return
        }
        let fraction = clockFraction - floor(clockFraction)
        switch fraction {
        case 0..<0.25:
            self = .topRight
        case 0.25..<0.5:
            self = .bottomRight
        case 0.5..<0.75:
            self = .bottomLeft
        default:
            self = .topLeft
        }
    }

    var isLeft: Bool {
        self == .topLeft || self == .bottomLeft
    }

    var isTop: Bool {
        self == .topLeft || self == .topRight
    }
}

enum CircularActivityLabelPaging {
    static func clampedIndex(_ index: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(index, 0), count - 1)
    }

    static func index(
        movingBy offset: Int,
        from index: Int,
        count: Int
    ) -> Int {
        clampedIndex(index + offset, count: count)
    }
}

enum CircularClockTapBand: Equatable {
    case phase
    case activity

    static func resolve(
        distance: Double,
        outerRadius: Double,
        phaseBandWidth: Double,
        bandGap: Double,
        activityBandWidth: Double,
        tolerance: Double = 8
    ) -> CircularClockTapBand? {
        let phaseRadius = outerRadius - phaseBandWidth / 2
        let activityRadius = outerRadius
            - phaseBandWidth
            - bandGap
            - activityBandWidth / 2
        let phaseDelta = abs(distance - phaseRadius)
        let activityDelta = abs(distance - activityRadius)
        let hitsPhase = phaseDelta <= phaseBandWidth / 2 + tolerance
        let hitsActivity = activityDelta <= activityBandWidth / 2 + tolerance

        switch (hitsPhase, hitsActivity) {
        case (true, true):
            return activityDelta <= phaseDelta ? .activity : .phase
        case (true, false):
            return .phase
        case (false, true):
            return .activity
        case (false, false):
            return nil
        }
    }
}

private struct CircularActivityLabel: Identifiable {
    let id: String
    let groupID: String
    let groupName: String
    let child: RecordGroupChild
    let start: Date
    let anchorFraction: Double
    let quadrant: CircularActivityLabelQuadrant
}

/// Scroll geometry can arrive faster than the SwiftUI layout budget. Keep the
/// latest offset outside view state and publish the playhead at most 60Hz.
private final class LinearScrollTracker {
    var latestOffset: CGFloat = 0
    var lastPublishedUptime: TimeInterval = 0
}

private final class CircularPlayheadTracker {
    var lastPublishedUptime: TimeInterval = 0
    var isDragging = false
}

private struct ReviewUnconfirmedSelection: Identifiable {
    let id = UUID()
    let span: TimeSpan
}

private struct ReviewQuickActivitySelection: Identifiable {
    let recordID: UUID
    let displayedSpan: TimeSpan

    var id: UUID {
        ActivityFragmentCorrectionEngine.stableID(
            sourceID: recordID,
            span: displayedSpan
        )
    }
}

private struct ReviewRecordSelection {
    let record: ActualRecord
    let displayedSpan: TimeSpan
}

private enum RecentActivitySelectionStore {
    private static let key = "review.recentActivityOptionIDs"
    private static let limit = 8

    static func ids() -> [String] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let ids = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    static func prioritize(
        _ options: [ActivityCorrectionOption]
    ) -> [ActivityCorrectionOption] {
        let recentIDs = ids()
        let rank = Dictionary(
            uniqueKeysWithValues: recentIDs.enumerated().map { ($1, $0) }
        )
        return options.enumerated()
            .sorted { left, right in
                let leftRank = rank[left.element.id]
                    ?? recentIDs.count + left.offset
                let rightRank = rank[right.element.id]
                    ?? recentIDs.count + right.offset
                return leftRank == rightRank
                    ? left.offset < right.offset
                    : leftRank < rightRank
            }
            .map(\.element)
    }

    static func remember(_ option: ActivityCorrectionOption) {
        var next = ids()
        next.removeAll { $0 == option.id }
        next.insert(option.id, at: 0)
        next = Array(next.prefix(limit))
        guard let data = try? JSONEncoder().encode(next) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

enum ActivityQuickSelectionPolicy {
    private static let placeholderTitles = [
        "", "활동", "머무름", "미확인",
    ]

    static func needsSelection(_ record: ActualRecord) -> Bool {
        let behavior = normalized(record.behavior)
        if behavior == WatchBehaviorKind.unknown.rawValue.lowercased()
            || behavior == StationaryContextKind.unknownStay.rawValue.lowercased() {
            return true
        }
        guard behavior == nil,
              ActualRecordCategoryResolver.categoryID(for: record) == "activity"
        else { return false }
        return placeholderTitles.contains(normalized(record.title))
    }

    static func isDetailedOption(_ option: ActivityCorrectionOption) -> Bool {
        let behavior = normalized(option.behavior)
        if behavior == WatchBehaviorKind.unknown.rawValue.lowercased()
            || behavior == StationaryContextKind.unknownStay.rawValue.lowercased() {
            return false
        }
        return !placeholderTitles.contains(normalized(option.title))
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

struct ReviewView: View {
    @Bindable var model: AppModel

    /// 24시간 눈금 안쪽에 기록을 담는 띠. 하나만 두고 굵게 그린다.
    private static let clockBandWidth: CGFloat = 20
    /// 활동 띠 바깥에 두르는 일과 띠.
    private static let phaseBandWidth: CGFloat = 12
    /// 일과와 활동 두 띠가 서로 붙어 보이지 않을 만큼만 벌린다.
    private static let bandGap: CGFloat = 3.5
    private static let clockButtonSize: CGFloat = 44
    private static let cornerLabelWidth: CGFloat = 108
    private static let cornerLabelHeight: CGFloat = 46
    /// 일과 띠를 두르면서 안쪽 띠가 가운데 단추와 읽음창에 밀리지 않도록
    /// 눈금판을 키웠다. 카드 너비(약 343pt)보다 작아 가로로 넘치지 않는다.
    ///
    /// 읽음창이 이름 옆에 "오전 11:12–오후 12:45"까지 적으면서 가운데 빈
    /// 자리가 더 필요해졌다. 띠를 모두 두르고 한 칸 띄우면 남는 반지름은
    /// `한 변/2 - 86`이고, 재생 단추 아래 알약은 가장 긴 문구일 때 가장 먼
    /// 모서리가 중심에서 약 75pt 떨어진다. 324pt면 76pt가 남는다. 더 좁은
    /// 화면에서는 한 변이 카드 너비에 묶이므로, 알약이 남은 자리에 맞춰
    /// 스스로 줄어든다.
    private static let clockHeight: CGFloat = 324
    private static let circularClockLegendMargin: CGFloat = 20
    private static let linearClockHeight: CGFloat = 174
    private static let linearTimelineHeight: CGFloat = 122
    private static let linearTimelineInset: CGFloat = 82
    private static let clockLinearThreshold: CGFloat = 1.08

    @State private var content = ReviewContent.empty
    @State private var collapsedGroupIDs: Set<String> = []
    /// 켜 둔 칸. 비어 있으면 기간 전체를 본다.
    @State private var selectedBucketIDs: Set<String> = []
    /// 주·월·년 막대에서 직접 고른 하루 또는 한 달.
    @State private var selectedChartBucketID: String?
    /// 범례에서 고른 한 항목. 서로 배타적으로 유지해 다른 띠는 흐리게 남긴다.
    @State private var clockHighlight: ReviewClockHighlight?
    @State private var circularActivityLabelPageIndices:
        [CircularActivityLabelQuadrant: Int] = [:]
    /// 재생을 시작한 시각. nil이면 멈춘 상태다.
    @State private var playStartedAt: Date?
    /// 하루 원형 시간표의 핀치 배율. 1배율은 원형, 그보다 크면 직선
    /// 시간표로 바꿔 두 줄(일과·활동)로 보여 준다.
    @State private var clockZoomScale: CGFloat = 1
    @State private var clockMagnifyOrigin: CGFloat?
    @State private var lastClockZoomRenderUptime: TimeInterval = 0
    @State private var linearScrollPosition = ScrollPosition(x: 0)
    @State private var linearPlayheadFraction = 0.5
    @State private var circularPlayheadFraction: Double?
    @State private var linearPositionedPeriodStart: Date?
    @State private var unconfirmedSelection: ReviewUnconfirmedSelection?
    @State private var quickActivitySelection: ReviewQuickActivitySelection?
    @State private var linearScrollTracker = LinearScrollTracker()
    @State private var circularPlayheadTracker = CircularPlayheadTracker()

    var body: some View {
        VStack(spacing: 0) {
            reviewHeader

            ScrollView(showsIndicators: false) {
                VStack(spacing: 10) {
                    chartCard
                    memoBreakdownCard
                    recordHierarchyCard
                    contextCard
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                // 하단 탭 막대 뒤로 마지막 줄이 숨지 않게 비워 둔다.
                .padding(.bottom, DraftBottomBarMetrics.contentInset)
            }
            .background(Color.tpBackground)
        }
        .task(id: contentKey) { rebuildContent() }
        .task(id: playStartedAt) { await stopPlaybackWhenSweepEnds() }
        .onDisappear { clearClockHighlight() }
        .onChange(of: model.reviewScale) { _, scale in
            if scale != .day {
                resetClockZoom()
                clearManualPlayhead()
            }
        }
        .onChange(of: clockHighlight) { _, _ in
            if !circularActivityLabelPageIndices.isEmpty {
                circularActivityLabelPageIndices = [:]
            }
        }
        .sheet(item: $unconfirmedSelection) { selection in
            ActivityCorrectionSheet(
                model: model,
                unconfirmedSpan: selection.span,
                showsQuickMenu: true
            )
        }
        .sheet(item: $quickActivitySelection) { selection in
            ActivityCorrectionSheet(
                model: model,
                recordID: selection.recordID,
                displayedSpan: selection.displayedSpan,
                showsQuickMenu: true
            )
        }
    }

    /// 과거 날짜는 하루 끝, 오늘은 재생을 시작한 현재 시각에서 멈춘다.
    private func stopPlaybackWhenSweepEnds() async {
        guard let startedAt = playStartedAt else { return }
        let end = RecordClockEngine.playbackEndFraction(
            in: content.period,
            asOf: startedAt
        )
        guard end > 0 else {
            if playStartedAt == startedAt { playStartedAt = nil }
            return
        }
        try? await Task.sleep(
            for: .seconds(RecordClockEngine.sweepDuration * end)
        )
        guard !Task.isCancelled, playStartedAt == startedAt else { return }
        playStartedAt = nil
    }

    private var highlightedCategoryID: String? {
        guard case .category(let id) = clockHighlight else { return nil }
        return id
    }

    private var highlightedDetail: ReviewDetailSelection? {
        guard case .detail(let selection) = clockHighlight else { return nil }
        return selection
    }

    private var highlightedPhaseToken: String? {
        guard case .phase(_, let token) = clockHighlight else { return nil }
        return token
    }

    private func clearClockHighlight() {
        guard clockHighlight != nil else { return }
        clockHighlight = nil
    }

    // MARK: - 머리말

    private var reviewHeader: some View {
        VStack(spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text("기록")
                    .font(.taption(size: 19, weight: .bold))
                Spacer()
                Text(periodText(content.period))
                    .font(.taption(size: 12))
                    .foregroundStyle(Color.tpSecondary)
            }

            HStack(spacing: 0) {
                ForEach(TimeScale.allCases) { scale in
                    Button {
                        selectedBucketIDs = []
                        selectedChartBucketID = nil
                        clearClockHighlight()
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

            if !content.pickableBuckets.isEmpty {
                bucketPicker
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 5)
        .padding(.bottom, 8)
        .background(Color.white)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.tpLine).frame(height: 0.5)
        }
    }

    /// 칸을 눌러 켜고 끈다. 여러 칸을 켜면 합쳐서 보고, 모두 끄면 기간
    /// 전체로 돌아간다. 따로 "고르기 모드"로 들어가지 않는다.
    private var bucketPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                if !selectedBucketIDs.isEmpty {
                    Button {
                        selectedBucketIDs = []
                        selectedChartBucketID = nil
                        clearClockHighlight()
                    } label: {
                        bucketChipLabel(
                            "전체",
                            isSelected: false,
                            symbol: "arrow.uturn.backward"
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("고른 칸 모두 끄기")
                }

                ForEach(content.pickableBuckets) { bucket in
                    let isSelected = selectedBucketIDs.contains(bucket.id)
                    Button {
                        toggle(bucket)
                    } label: {
                        bucketChipLabel(bucket.label, isSelected: isSelected)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(bucket.label)
                    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                }
            }
            .padding(.horizontal, 1)
            .padding(.vertical, 1)
        }
        .frame(height: 30)
    }

    private func bucketChipLabel(
        _ text: String,
        isSelected: Bool,
        symbol: String? = nil
    ) -> some View {
        HStack(spacing: 3) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.taption(size: 8, weight: .bold))
            }
            Text(text)
                .font(
                    .taption(
                        size: 10,
                        weight: isSelected ? .bold : .regular
                    )
                )
        }
        .foregroundStyle(isSelected ? Color.tpProjectDark : Color.tpSecondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(
            isSelected
                ? Color.tpProjectDark.opacity(0.16)
                : Color(red: 0.95, green: 0.95, blue: 0.96),
            in: Capsule()
        )
        .overlay {
            Capsule().stroke(
                isSelected ? Color.tpProjectDark.opacity(0.55) : .clear,
                lineWidth: 1
            )
        }
    }

    private func toggle(_ bucket: ReviewPeriodBucket) {
        clearClockHighlight()
        selectedChartBucketID = nil
        if selectedBucketIDs.contains(bucket.id) {
            selectedBucketIDs.remove(bucket.id)
        } else {
            selectedBucketIDs.insert(bucket.id)
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

            // 하루 눈금판은 기록이 없어도 남는다. 옆으로 넘길 자리가 있어야 한다.
            if model.reviewScale == .day {
                timelineLocationHeader
                dayClockChart
                VStack(alignment: .leading, spacing: 9) {
                    // 범례도 고리와 같은 순서로 밖에서 안으로 읽힌다.
                    if let phaseRing = content.phaseRing {
                        phaseLegend(phaseRing)
                    }
                    if content.groups.isEmpty {
                        emptyRecordText
                    } else {
                        categoryLegend
                    }
                }
                .padding(
                    .top,
                    clockZoomScale < Self.clockLinearThreshold
                        ? Self.circularClockLegendMargin
                        : 0
                )
            } else if content.phaseDurations.isEmpty {
                emptyRecordText
            } else {
                barChart
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

    private var emptyRecordText: some View {
        Text("이 기간에 저장된 실제 데이터가 없습니다.")
            .font(.taption(size: 10.5))
            .foregroundStyle(Color.tpSecondary)
    }

    private var timelineLocationHeader: some View {
        HStack(spacing: 5) {
            Image(systemName: "mappin.and.ellipse")
                .font(.taption(size: 10, weight: .semibold))
                .foregroundStyle(Color.tpPlaceDark)
            Text(timelineLocationText)
                .font(.taption(size: 9, weight: .semibold))
                .foregroundStyle(
                    timelineLocationText == "위치 정보 없음"
                        ? Color.tpSecondary
                        : Color.tpInk
                )
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 18, alignment: .leading)
        .padding(.horizontal, 3)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.tpLine.opacity(0.35))
                .frame(height: 0.5)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("현재 위치")
    }

    private var timelineLocationText: String {
        let fraction = clockZoomScale >= Self.clockLinearThreshold
            ? linearLookupFraction
            : (circularPlayheadFraction
                ?? RecordClockEngine.nowFraction(
                    in: content.period,
                    asOf: Date.now
                )
                ?? 0)
        let token = content.contextRings
            .first(where: { $0.kind == .location })?
            .arcs
            .filter { $0.startFraction <= fraction + 0.0001 }
            .max { $0.startFraction < $1.startFraction }?
            .token
        return token.map { detailName(.location, token: $0) } ?? "위치 정보 없음"
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
        if model.reviewScale == .day {
            return content.period.duration
        }
        return content.phaseDurations.reduce(0) { $0 + $1.actual }
    }

    /// 24시간 눈금판. 자정이 12시 방향이고 시계 방향으로 하루가 흐른다.
    /// 평소에는 눈금과 현재 시각 바늘만 두고, 기록은 재생하거나 범례에서
    /// 카테고리를 고를 때만 안쪽 띠에 굵게 드러낸다.
    private var dayClockChart: some View {
        Group {
            if clockZoomScale >= Self.clockLinearThreshold {
                linearDayClockChart
            } else {
                circularDayClockChart
            }
        }
        .animation(.easeOut(duration: 0.16), value: clockZoomScale >= Self.clockLinearThreshold)
    }

    private var circularDayClockChart: some View {
        let rings = content.rings
        let activityRings = content.activityRings
        let phaseRing = content.phaseRing
        let pinnedPhaseArc = highlightedPhaseArc
        let highlight = clockHighlight
        let span = content.period
        let currentReadout = currentContextReadout()
        return TimelineView(
            RecordClockSchedule(isPlaying: playStartedAt != nil)
        ) { timeline in
            let playbackProgress = clockPlaybackProgress(at: timeline.date)
            let progress = playbackProgress ?? circularPlayheadFraction
            ZStack {
                Canvas { context, size in
                    drawClock(
                        context: context,
                        size: size,
                        rings: rings,
                        phaseRing: phaseRing,
                        pinnedPhaseArc: pinnedPhaseArc,
                        activityRings: activityRings,
                        highlight: highlight,
                        progress: progress,
                        span: span,
                        nowFraction: idleCircularPlayheadFraction(
                            at: timeline.date
                        )
                    )
                }
                if let progress {
                    if let readout = playbackContext(
                        at: progress,
                        in: content.contextRings
                    ), !readout.isEmpty {
                        playbackContextView(readout)
                            .offset(y: Self.clockButtonSize / 2 + 24)
                            .allowsHitTesting(false)
                    }
                } else if let currentReadout, !currentReadout.isEmpty {
                    playbackContextView(currentReadout)
                        .offset(y: Self.clockButtonSize / 2 + 24)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(height: Self.clockHeight)
        .overlay { clockTapLayer }
        .overlay { circularActivityLeaderLines }
        .overlay { circularActivityLabels }
        .overlay { circularPlayheadOverlay }
        .overlay { playControl }
        .coordinateSpace(name: "recordCircularClock")
        .contentShape(Rectangle())
        // 목록을 위아래로 굴리는 손가락을 가로채지 않도록 함께 인식시킨다.
        .simultaneousGesture(dateSwipeGesture)
        // The surrounding record view is a vertical ScrollView. Prioritize
        // the two-finger recognizer so scrolling cannot consume the pinch.
        .highPriorityGesture(clockMagnifyGesture, including: .subviews)
        .background {
            TwoFingerPinchAttachment(
                onChanged: { factor, _ in
                    updateClockZoom(factor: factor)
                },
                onEnded: { factor, _ in
                    finishClockZoom(factor: factor)
                }
            )
        }
        .accessibilityLabel("하루 24시간 눈금판")
    }

    private var circularPlayheadOverlay: some View {
        TimelineView(
            RecordClockSchedule(isPlaying: playStartedAt != nil)
        ) { timeline in
            let fraction = clockPlaybackProgress(at: timeline.date)
                ?? idleCircularPlayheadFraction(at: timeline.date)
            circularPlayheadHandle(at: fraction)
        }
    }

    private func circularPlayheadHandle(at fraction: Double) -> some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let center = CGPoint(
                x: proxy.size.width / 2,
                y: proxy.size.height / 2
            )
            let tip = point(
                center: center,
                radius: side / 2 - 15,
                angle: clockAngle(fraction)
            )
            ZStack {
                Circle().fill(Color.clear)
                Circle()
                    .fill(Color.tpNow)
                    .frame(width: 10, height: 10)
                    .overlay(Circle().stroke(.white, lineWidth: 1.5))
                    .shadow(color: .black.opacity(0.16), radius: 1, y: 1)
            }
            .frame(width: 32, height: 32)
            .contentShape(Circle())
            .position(tip)
            .gesture(
                DragGesture(
                    minimumDistance: 0,
                    coordinateSpace: .named("recordCircularClock")
                )
                .onChanged { value in
                    updateCircularPlayhead(
                        at: value.location,
                        in: proxy.size
                    )
                }
                .onEnded { value in
                    finishCircularPlayheadDrag(
                        at: value.location,
                        in: proxy.size
                    )
                }
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("시간 플레이헤드")
            .accessibilityValue(circularPlayheadTimeText(fraction))
            .accessibilityHint("15분씩 조절할 수 있습니다")
            .accessibilityAdjustableAction(adjustCircularPlayhead)
        }
    }

    private func clockPlaybackProgress(at date: Date) -> Double? {
        guard let startedAt = playStartedAt else { return nil }
        return RecordClockEngine.progress(
            start: startedAt,
            now: date,
            endFraction: RecordClockEngine.playbackEndFraction(
                in: content.period,
                asOf: startedAt
            )
        )
    }

    private func idleCircularPlayheadFraction(at date: Date) -> Double {
        circularPlayheadFraction
            ?? RecordClockEngine.nowFraction(in: content.period, asOf: date)
            ?? 0
    }

    private var circularActivityLabels: some View {
        let labels = Dictionary(
            grouping: circularActivityLabelItems,
            by: \.quadrant
        )
        return VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 4) {
                circularActivityLabel(in: .topLeft, from: labels)
                Spacer(minLength: 4)
                circularActivityLabel(in: .topRight, from: labels)
            }
            Spacer(minLength: 0)
            HStack(alignment: .bottom, spacing: 4) {
                circularActivityLabel(in: .bottomLeft, from: labels)
                Spacer(minLength: 4)
                circularActivityLabel(in: .bottomRight, from: labels)
            }
        }
        .padding(.horizontal, 3)
        .padding(.vertical, 4)
    }

    private var circularActivityLeaderLines: some View {
        let labels = Dictionary(
            grouping: circularActivityLabelItems,
            by: \.quadrant
        )
        return Canvas { context, size in
            drawCircularActivityLeaderLines(
                context: context,
                size: size,
                labels: visibleCircularActivityLabels(in: labels)
            )
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func drawCircularActivityLeaderLines(
        context: GraphicsContext,
        size: CGSize,
        labels: [CircularActivityLabel]
    ) {
        guard !labels.isEmpty else { return }
        let side = min(size.width, size.height)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let outer = side / 2 - 24
        let lineRadius = outer + 2

        for item in labels {
            let start = point(
                center: center,
                radius: lineRadius,
                angle: clockAngle(item.anchorFraction)
            )
            let anchor = circularActivityLabelAnchor(
                quadrant: item.quadrant,
                in: size
            )
            let elbow = CGPoint(
                x: anchor.x + (item.quadrant.isLeft ? 14 : -14),
                y: anchor.y
            )
            var path = Path()
            path.move(to: start)
            path.addLine(to: elbow)
            path.addLine(to: anchor)
            context.stroke(
                path,
                with: .color(
                    color(forCategoryID: item.groupID).opacity(0.7)
                ),
                style: StrokeStyle(lineWidth: 0.9, lineCap: .round)
            )
            context.fill(
                Path(
                    ellipseIn: CGRect(
                        x: start.x - 2.2,
                        y: start.y - 2.2,
                        width: 4.4,
                        height: 4.4
                    )
                ),
                with: .color(color(forCategoryID: item.groupID))
            )
        }
    }

    private func circularActivityLabelAnchor(
        quadrant: CircularActivityLabelQuadrant,
        in size: CGSize
    ) -> CGPoint {
        let x = quadrant.isLeft
            ? 3 + Self.cornerLabelWidth
            : size.width - 3 - Self.cornerLabelWidth
        let y = quadrant.isTop
            ? 4 + Self.cornerLabelHeight / 2
            : size.height - 4 - Self.cornerLabelHeight / 2
        return CGPoint(x: x, y: y)
    }

    @ViewBuilder
    private func circularActivityLabel(
        in quadrant: CircularActivityLabelQuadrant,
        from labels: [CircularActivityLabelQuadrant: [CircularActivityLabel]]
    ) -> some View {
        let items = labels[quadrant] ?? []
        if !items.isEmpty {
            let index = CircularActivityLabelPaging.clampedIndex(
                circularActivityLabelPageIndices[quadrant] ?? 0,
                count: items.count
            )
            circularActivityLabel(
                items[index],
                quadrant: quadrant,
                index: index,
                count: items.count
            )
        } else {
            Color.clear
                .frame(
                    width: Self.cornerLabelWidth,
                    height: Self.cornerLabelHeight
                )
                .accessibilityHidden(true)
        }
    }

    private var circularActivityLabelItems: [CircularActivityLabel] {
        let period = content.period
        guard period.duration > 0 else { return [] }
        let actuals: [UUID: ActualRecord] = Dictionary(
            content.displayActuals.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        let source: RecordCategoryGroup?
        let detailIntervals: [TimeSpan]?
        switch clockHighlight {
        case .phase(_, let token):
            source = content.phaseGroups.first { $0.id == token }
            detailIntervals = nil
        case .category(let categoryID):
            source = content.groups.first { $0.id == categoryID }
            detailIntervals = nil
        case .detail(let selection):
            let categoryID = activityCategoryID(for: selection.kind)
            source = categoryID.flatMap { id in
                content.groups.first { $0.id == id }
            }
            detailIntervals = detailSpans(for: selection)
        case nil:
            source = nil
            detailIntervals = nil
        }
        guard let source else { return [] }

        let now = Date.now
        return source.children.compactMap { child in
            guard let actual = actuals[child.recordID],
                  let clipped = actual.span(asOf: now)
                      .intersection(with: period),
                  clipped.duration > 0 else { return nil }

            let matching: [TimeSpan]
            if let detailIntervals {
                matching = detailIntervals.compactMap {
                    clipped.intersection(with: $0)
                }
                guard !matching.isEmpty else { return nil }
            } else {
                matching = [clipped]
            }

            let visible = ActualIntervalMergeEngine.union(matching)
            guard let labelSpan = visible.first else { return nil }
            let midpoint = labelSpan.start.addingTimeInterval(
                labelSpan.duration / 2
            )
            let elapsed = midpoint.timeIntervalSince(period.start)
            let fraction = min(
                1 - 0.000_001,
                max(0, elapsed / period.duration)
            )
            let labelChild = RecordGroupChild(
                id: child.id,
                title: child.title,
                duration: detailIntervals == nil
                    ? child.duration
                    : visible.reduce(0) { $0 + $1.duration },
                start: labelSpan.start,
                recordID: child.recordID,
                occurrenceCount: child.occurrenceCount
            )
            let labelID = source.id + "." + child.id
            return CircularActivityLabel(
                id: labelID,
                groupID: source.id,
                groupName: source.name,
                child: labelChild,
                start: labelSpan.start,
                anchorFraction: fraction,
                quadrant: CircularActivityLabelQuadrant(
                    clockFraction: fraction
                )
            )
        }
        .sorted {
            $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start
        }
    }

    private func detailSpans(
        for selection: ReviewDetailSelection
    ) -> [TimeSpan] {
        guard let ring = content.activityRings.first(where: {
            $0.kind == selection.kind
        }) else { return [] }
        return ring.arcs
            .filter { $0.token == selection.token }
            .map { RecordClockEngine.span(of: $0, in: content.period) }
    }

    private func visibleCircularActivityLabels(
        in labels: [CircularActivityLabelQuadrant: [CircularActivityLabel]]
    ) -> [CircularActivityLabel] {
        CircularActivityLabelQuadrant.allCases.compactMap { quadrant in
            guard let items = labels[quadrant], !items.isEmpty else {
                return nil
            }
            let index = CircularActivityLabelPaging.clampedIndex(
                circularActivityLabelPageIndices[quadrant] ?? 0,
                count: items.count
            )
            return items[index]
        }
    }

    private func circularActivityLabel(
        _ item: CircularActivityLabel,
        quadrant: CircularActivityLabelQuadrant,
        index: Int,
        count: Int
    ) -> some View {
        ZStack(alignment: .bottomTrailing) {
            Button {
                // 하단 실제 기록의 자식 행과 같은 상세 화면을 연다.
                clearClockHighlight()
                if let selection = recordForRing(
                    at: item.anchorFraction,
                    categoryID: nil
                ) {
                    model.detail = .actualSegment(
                        selection.record.id,
                        selection.displayedSpan
                    )
                } else {
                    model.detail = .actual(item.child.recordID)
                }
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.child.title)
                        .font(.taption(size: 8.5, weight: .semibold))
                        .foregroundStyle(color(forCategoryID: item.groupID))
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                    Text(
                        "\(item.groupName) · "
                            + DurationText.koreanAtLeastAMinute(
                                item.child.duration
                            )
                    )
                    .font(.taption(size: 7.5))
                    .foregroundStyle(Color.tpSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                }
                .padding(.horizontal, 6)
                .padding(.top, 4)
                .padding(.bottom, count > 1 ? 16 : 4)
                .frame(
                    width: Self.cornerLabelWidth,
                    height: Self.cornerLabelHeight,
                    alignment: .topLeading
                )
                .background(
                    Color.white.opacity(0.96),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(
                            color(forCategoryID: item.groupID).opacity(0.45),
                            lineWidth: 0.8
                        )
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                "\(item.groupName) \(item.child.title) 상세 보기"
            )

            if count > 1 {
                HStack(spacing: 2) {
                    circularActivityPageButton(
                        symbol: "chevron.left",
                        label: "이전 활동 라벨",
                        isDisabled: index == 0
                    ) {
                        moveCircularActivityLabel(
                            in: quadrant,
                            by: -1,
                            count: count
                        )
                    }
                    Text("\(index + 1)/\(count)")
                        .font(.taption(size: 6.5, weight: .semibold))
                        .foregroundStyle(Color.tpSecondary)
                        .monospacedDigit()
                    circularActivityPageButton(
                        symbol: "chevron.right",
                        label: "다음 활동 라벨",
                        isDisabled: index == count - 1
                    ) {
                        moveCircularActivityLabel(
                            in: quadrant,
                            by: 1,
                            count: count
                        )
                    }
                }
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
                .background(
                    Color.white.opacity(0.98),
                    in: Capsule()
                )
                .padding(.trailing, 3)
                .padding(.bottom, 2)
            }
        }
        .frame(
            width: Self.cornerLabelWidth,
            height: Self.cornerLabelHeight
        )
    }

    private func circularActivityPageButton(
        symbol: String,
        label: String,
        isDisabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.taption(size: 7, weight: .bold))
                .frame(width: 15, height: 13)
                .foregroundStyle(
                    isDisabled
                        ? Color.tpSecondary.opacity(0.3)
                        : Color.tpInk
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .accessibilityLabel(label)
    }

    private func moveCircularActivityLabel(
        in quadrant: CircularActivityLabelQuadrant,
        by offset: Int,
        count: Int
    ) {
        let current = CircularActivityLabelPaging.clampedIndex(
            circularActivityLabelPageIndices[quadrant] ?? 0,
            count: count
        )
        let next = CircularActivityLabelPaging.index(
            movingBy: offset,
            from: current,
            count: count
        )
        guard next != current else { return }
        circularActivityLabelPageIndices[quadrant] = next
    }

    private var linearDayClockChart: some View {
        TimelineView(
            RecordClockSchedule(isPlaying: playStartedAt != nil)
        ) { timeline in
            let progress = clockPlaybackProgress(at: timeline.date)
            GeometryReader { proxy in
                let labelWidth = Self.linearTimelineInset
                let viewportWidth = max(proxy.size.width - labelWidth, 1)
                let timelineWidth = max(
                    viewportWidth,
                    viewportWidth * clockZoomScale
                )
                VStack(spacing: 8) {
                    HStack(spacing: 0) {
                        linearPlayheadLabels
                            .frame(
                                width: labelWidth,
                                height: Self.linearTimelineHeight
                            )
                        ZStack {
                            ScrollView(.horizontal, showsIndicators: false) {
                                Canvas { context, size in
                                    drawLinearClock(
                                        context: context,
                                        size: size,
                                        timelineStart: viewportWidth / 2,
                                        timelineWidth: timelineWidth,
                                        rings: content.rings,
                                        phaseRing: content.phaseRing,
                                        activityRings: content.activityRings,
                                        highlight: clockHighlight,
                                        progress: progress
                                    )
                                }
                                .frame(
                                    width: timelineWidth + viewportWidth,
                                    height: Self.linearTimelineHeight
                                )
                                .contentShape(Rectangle())
                                .onTapGesture { location in
                                    guard location.y < 82 else { return }
                                    openLinearRecordEditor(
                                        at: location.x,
                                        timelineStart: viewportWidth / 2,
                                        timelineWidth: timelineWidth
                                    )
                                }
                            }
                            .scrollPosition($linearScrollPosition)
                            .onScrollGeometryChange(for: CGFloat.self) {
                                $0.contentOffset.x
                            } action: { _, offset in
                                updateLinearPlayhead(
                                    offset: offset,
                                    timelineWidth: timelineWidth
                                )
                            }
                            .onScrollPhaseChange { _, phase in
                                if phase == .idle {
                                    updateLinearPlayhead(
                                        offset: linearScrollTracker.latestOffset,
                                        timelineWidth: timelineWidth,
                                        force: true
                                    )
                                }
                                guard phase == .tracking || phase == .interacting,
                                      playStartedAt != nil else { return }
                                playStartedAt = nil
                            }
                            .onAppear {
                                positionLinearTimeline(
                                    timelineWidth: timelineWidth,
                                    asOf: timeline.date
                                )
                            }
                            .onChange(of: timelineWidth) { _, _ in
                                positionLinearTimeline(
                                    timelineWidth: timelineWidth,
                                    asOf: timeline.date
                                )
                            }
                            .onChange(of: content.period.start) { _, _ in
                                positionLinearTimeline(
                                    timelineWidth: timelineWidth,
                                    asOf: timeline.date,
                                    resetsTime: true
                                )
                            }
                            .onChange(of: progress) { _, fraction in
                                guard let fraction else { return }
                                moveLinearTimeline(
                                    to: fraction,
                                    timelineWidth: timelineWidth
                                )
                            }

                            linearPlayhead
                                .allowsHitTesting(false)
                        }
                    }
                    playControl
                }
            }
        }
        .frame(height: Self.linearClockHeight)
        .contentShape(Rectangle())
        .highPriorityGesture(clockMagnifyGesture, including: .subviews)
        .background {
            TwoFingerPinchAttachment(
                onChanged: { factor, _ in
                    updateClockZoom(factor: factor)
                },
                onEnded: { factor, _ in
                    finishClockZoom(factor: factor)
                }
            )
        }
        .accessibilityLabel("확대된 하루 24시간 직선 시간표")
        .accessibilityValue("일과와 상세활동 두 줄")
    }

    private var linearPlayheadLabels: some View {
        VStack(spacing: 0) {
            linearPlayheadLabel("일과", item: linearPhaseItem)
                .frame(height: 40)
            linearPlayheadLabel("상세활동", item: linearActivityItem)
                .frame(height: 40)
            Text(linearPlayheadTimeText)
                .font(.taption(size: 8.5, weight: .bold))
                .foregroundStyle(Color.tpNow)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.trailing, 6)
    }

    private func linearPlayheadLabel(
        _ title: String,
        item: LinearClockItem
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.taption(size: 7.5, weight: .bold))
                .foregroundStyle(Color.tpSecondary)
            HStack(spacing: 4) {
                Circle()
                    .fill(item.tint)
                    .frame(width: 6, height: 6)
                Text(item.title)
                    .font(.taption(size: 9, weight: .bold))
                    .foregroundStyle(Color.tpInk)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var linearPhaseItem: LinearClockItem {
        guard let arc = RecordClockEngine.arc(
            in: content.phaseRing,
            at: linearLookupFraction
        ) else {
            return LinearClockItem(
                title: "미확인",
                tint: detailColor(.dayPhase, token: DayPhase.unconfirmed.rawValue)
            )
        }
        return LinearClockItem(
            title: detailName(.dayPhase, token: arc.token),
            tint: detailColor(.dayPhase, token: arc.token)
        )
    }

    private var linearActivityItem: LinearClockItem {
        guard let ring = content.rings.first(where: { ring in
            ring.arcs.contains {
                $0.startFraction <= linearLookupFraction
                    && linearLookupFraction < $0.endFraction
            }
        }) else {
            return LinearClockItem(
                title: "미확인",
                tint: color(forCategoryID: ReviewCoverageEngine.unconfirmedCategoryID)
            )
        }

        let detailKind: RecordClockDetailKind? = switch ring.categoryID {
        case TimelineRowKind.sleep.rawValue: .sleepStage
        case TimelineRowKind.movement.rawValue: .travel
        default: nil
        }
        if let detailKind,
           let detailRing = content.activityRings.first(
               where: { $0.kind == detailKind }
           ),
           let arc = RecordClockEngine.arc(
               in: detailRing,
               at: linearLookupFraction
           ) {
            return LinearClockItem(
                title: detailName(detailKind, token: arc.token),
                tint: detailColor(detailKind, token: arc.token)
            )
        }
        return LinearClockItem(
            title: categoryName(ring.categoryID),
            tint: color(forCategoryID: ring.categoryID)
        )
    }

    private var linearPlayheadTimeText: String {
        content.period.start
            .addingTimeInterval(
                content.period.duration * linearPlayheadFraction
            )
            .formatted(date: .omitted, time: .shortened)
    }

    private var linearLookupFraction: Double {
        min(linearPlayheadFraction, 1 - 0.000_001)
    }

    private var linearPlayhead: some View {
        Canvas { context, size in
            let x = size.width / 2
            context.stroke(
                Path { path in
                    path.move(to: CGPoint(x: x, y: 3))
                    path.addLine(to: CGPoint(x: x, y: 99))
                },
                with: .color(Color.tpNow),
                style: StrokeStyle(lineWidth: 1.6, lineCap: .round)
            )
            context.fill(
                Path(ellipseIn: CGRect(x: x - 3.5, y: 0, width: 7, height: 7)),
                with: .color(Color.tpNow)
            )
        }
    }

    private func updateCircularPlayhead(
        at location: CGPoint,
        in size: CGSize,
        force: Bool = false
    ) {
        if !circularPlayheadTracker.isDragging {
            circularPlayheadTracker.isDragging = true
            circularPlayheadTracker.lastPublishedUptime = 0
            if playStartedAt != nil { playStartedAt = nil }
            clearClockHighlight()
        }
        let now = ProcessInfo.processInfo.systemUptime
        guard force
            || circularPlayheadTracker.lastPublishedUptime == 0
            || now - circularPlayheadTracker.lastPublishedUptime >= 1.0 / 60.0
        else { return }
        circularPlayheadTracker.lastPublishedUptime = now
        setManualPlayhead(
            RecordClockEngine.clockFraction(
                x: Double(location.x),
                y: Double(location.y),
                centerX: Double(size.width / 2),
                centerY: Double(size.height / 2)
            )
        )
    }

    private func finishCircularPlayheadDrag(
        at location: CGPoint,
        in size: CGSize
    ) {
        updateCircularPlayhead(at: location, in: size, force: true)
        circularPlayheadTracker.lastPublishedUptime = 0
        Task { @MainActor in
            await Task.yield()
            circularPlayheadTracker.isDragging = false
        }
    }

    private func setManualPlayhead(_ fraction: Double) {
        let next = min(1, max(0, fraction))
        if circularPlayheadFraction.map({ abs($0 - next) > 0.00001 })
            != false {
            circularPlayheadFraction = next
        }
        if abs(linearPlayheadFraction - next) > 0.00001 {
            linearPlayheadFraction = next
        }
    }

    private func clearManualPlayhead() {
        guard circularPlayheadFraction != nil else { return }
        circularPlayheadFraction = nil
        circularPlayheadTracker.lastPublishedUptime = 0
    }

    private func adjustCircularPlayhead(
        _ direction: AccessibilityAdjustmentDirection
    ) {
        guard content.period.duration > 0 else { return }
        let current = clockPlaybackProgress(at: Date.now)
            ?? idleCircularPlayheadFraction(at: Date.now)
        let step = 15 * 60 / content.period.duration
        let offset: Double
        switch direction {
        case .increment: offset = step
        case .decrement: offset = -step
        @unknown default: return
        }
        if playStartedAt != nil { playStartedAt = nil }
        var next = current + offset
        if next < 0 { next += 1 }
        if next > 1 { next -= 1 }
        setManualPlayhead(next)
    }

    private func circularPlayheadTimeText(_ fraction: Double) -> String {
        content.period.start
            .addingTimeInterval(content.period.duration * fraction)
            .formatted(date: .omitted, time: .shortened)
    }

    private func updateLinearPlayhead(
        offset: CGFloat,
        timelineWidth: CGFloat,
        force: Bool = false
    ) {
        linearScrollTracker.latestOffset = offset
        let now = ProcessInfo.processInfo.systemUptime
        guard force
            || now - linearScrollTracker.lastPublishedUptime >= 1.0 / 60.0
        else { return }
        linearScrollTracker.lastPublishedUptime = now
        let next = RecordClockEngine.playheadFraction(
            contentOffset: Double(offset),
            timelineWidth: Double(timelineWidth)
        )
        guard abs(next - linearPlayheadFraction) > 0.00001 else { return }
        linearPlayheadFraction = next
        if playStartedAt == nil,
           circularPlayheadFraction.map({ abs($0 - next) > 0.00001 }) != false {
            circularPlayheadFraction = next
        }
    }

    private func positionLinearTimeline(
        timelineWidth: CGFloat,
        asOf date: Date,
        resetsTime: Bool = false
    ) {
        if resetsTime || linearPositionedPeriodStart != content.period.start {
            let next = circularPlayheadFraction
                ?? RecordClockEngine.nowFraction(
                    in: content.period,
                    asOf: date
                )
                ?? 0.5
            if next != linearPlayheadFraction { linearPlayheadFraction = next }
            linearPositionedPeriodStart = content.period.start
        }
        moveLinearTimeline(
            to: linearPlayheadFraction,
            timelineWidth: timelineWidth
        )
    }

    private func moveLinearTimeline(
        to fraction: Double,
        timelineWidth: CGFloat
    ) {
        let next = min(1, max(0, fraction))
        if next != linearPlayheadFraction { linearPlayheadFraction = next }
        linearScrollPosition.scrollTo(
            x: CGFloat(
                RecordClockEngine.contentOffset(
                    for: next,
                    timelineWidth: Double(timelineWidth)
                )
            )
        )
    }

    private func drawLinearClock(
        context: GraphicsContext,
        size: CGSize,
        timelineStart: CGFloat,
        timelineWidth: CGFloat,
        rings: [RecordClockRing],
        phaseRing: RecordClockDetailRing?,
        activityRings: [RecordClockDetailRing],
        highlight: ReviewClockHighlight?,
        progress: Double?
    ) {
        let phaseRect = CGRect(
            x: timelineStart,
            y: 7,
            width: timelineWidth,
            height: 27
        )
        let activityRect = CGRect(
            x: timelineStart,
            y: 44,
            width: timelineWidth,
            height: 30
        )

        drawLinearGrid(
            context: context,
            timelineStart: timelineStart,
            width: timelineWidth
        )

        let revealedPhase = RecordClockEngine.detailRing(
            phaseRing,
            revealedThrough: progress
        )
        if let revealedPhase {
            drawLinearDetailArcs(
                context: context,
                arcs: revealedPhase.arcs,
                rect: phaseRect,
                color: { detailColor(.dayPhase, token: $0) },
                opacity: { token in
                    phaseOpacity(
                        token: token,
                        focusedToken: nil,
                        highlight: highlight,
                        isPlaying: progress != nil
                    )
                }
            )
        } else {
            drawLinearPlaceholder(
                context: context,
                rect: phaseRect,
                color: Color.tpLine.opacity(0.35)
            )
        }

        let revealedRings = RecordClockEngine.rings(
            rings,
            revealedThrough: progress
        )
        let active = progress.map {
            RecordClockEngine.categoryIDs(in: rings, at: $0)
        } ?? Set<String>()
        for pass in [false, true] {
            for ring in revealedRings
            where active.contains(ring.categoryID) == pass {
                drawLinearCategoryArcs(
                    context: context,
                    arcs: ring.arcs,
                    rect: activityRect,
                    color: color(forCategoryID: ring.categoryID),
                    opacity: activityOpacity(
                        categoryID: ring.categoryID,
                        highlight: highlight,
                        isPlaybackActive: progress != nil,
                        isUnderPlayhead: pass
                    )
                )
            }
        }

        let details = RecordClockEngine.detailRings(
            activityRings,
            revealedThrough: progress
        )
        for ring in details {
            drawLinearDetailArcs(
                context: context,
                arcs: ring.arcs,
                rect: activityRect.insetBy(dx: 0, dy: 5),
                color: { detailColor(ring.kind, token: $0) },
                opacity: { token in
                    activityDetailOpacity(
                        kind: ring.kind,
                        token: token,
                        highlight: highlight
                    )
                }
            )
        }

    }

    private func drawLinearGrid(
        context: GraphicsContext,
        timelineStart: CGFloat,
        width: CGFloat
    ) {
        for quarter in 0...96 {
            let x = timelineStart + width * CGFloat(quarter) / 96
            let isHour = quarter.isMultiple(of: 4)
            let isHalfHour = quarter.isMultiple(of: 2)
            context.stroke(
                Path { path in
                    path.move(to: CGPoint(x: x, y: 4))
                    path.addLine(to: CGPoint(x: x, y: 78))
                },
                with: .color(Color.tpLine.opacity(isHour ? 0.38 : 0.13)),
                lineWidth: isHour ? 0.9 : 0.5
            )

            context.stroke(
                Path { path in
                    path.move(to: CGPoint(x: x, y: 84))
                    path.addLine(
                        to: CGPoint(
                            x: x,
                            y: isHour ? 96 : (isHalfHour ? 92 : 89)
                        )
                    )
                },
                with: .color(Color.tpSecondary.opacity(0.72)),
                lineWidth: isHour ? 1 : 0.6
            )

            guard isHour else { continue }
            let hour = quarter / 4
            let labelStride = width < 560 ? 3 : (width < 900 ? 2 : 1)
            guard hour.isMultiple(of: labelStride) else { continue }
            let label = context.resolve(
                Text(String(format: "%02d:00", hour))
                    .font(.taption(size: 8, weight: .bold))
                    .foregroundStyle(Color.tpSecondary)
            )
            context.draw(label, at: CGPoint(x: x, y: 108))
        }
    }

    private func drawLinearPlaceholder(
        context: GraphicsContext,
        rect: CGRect,
        color: Color
    ) {
        context.fill(
            Path(roundedRect: rect, cornerRadius: 7),
            with: .color(color)
        )
    }

    private func drawLinearCategoryArcs(
        context: GraphicsContext,
        arcs: [RecordClockArc],
        rect: CGRect,
        color: Color,
        opacity: Double
    ) {
        for arc in arcs {
            let x = rect.minX + rect.width * arc.startFraction
            let end = rect.minX + rect.width * arc.endFraction
            let bar = CGRect(
                x: x,
                y: rect.minY,
                width: max(1, end - x),
                height: rect.height
            )
            context.fill(
                Path(roundedRect: bar, cornerRadius: 7),
                with: .color(color.opacity(opacity))
            )
        }
    }

    private func drawLinearDetailArcs(
        context: GraphicsContext,
        arcs: [RecordClockDetailArc],
        rect: CGRect,
        color: (String) -> Color,
        opacity: (String) -> Double
    ) {
        for arc in arcs {
            let x = rect.minX + rect.width * arc.startFraction
            let end = rect.minX + rect.width * arc.endFraction
            let bar = CGRect(
                x: x,
                y: rect.minY,
                width: max(1, end - x),
                height: rect.height
            )
            context.fill(
                Path(roundedRect: bar, cornerRadius: 5),
                with: .color(color(arc.token).opacity(opacity(arc.token)))
            )
        }
    }

    private func openLinearRecordEditor(
        at x: CGFloat,
        timelineStart: CGFloat,
        timelineWidth: CGFloat
    ) {
        let fraction = min(
            1 - 0.000_001,
            max(0, (x - timelineStart) / timelineWidth)
        )
        if let selection = recordForRing(at: fraction, categoryID: nil) {
            openRecord(selection)
        } else {
            openUnconfirmedEditor(at: fraction, categoryID: nil)
        }
    }

    private func updateClockZoom(factor: CGFloat) {
        if clockMagnifyOrigin == nil {
            clockMagnifyOrigin = clockZoomScale
            TaptionPlanDiagnosticsLogger.shared.record(
                "record_clock_zoom_began",
                fields: [
                    "factor": String(format: "%.3f", factor),
                    "scale": String(format: "%.3f", clockZoomScale),
                ]
            )
        }
        let now = ProcessInfo.processInfo.systemUptime
        guard lastClockZoomRenderUptime == 0
            || now - lastClockZoomRenderUptime >= 1.0 / 60.0
        else { return }
        lastClockZoomRenderUptime = now
        guard let origin = clockMagnifyOrigin else { return }
        let next = min(4, max(1, origin * max(0.01, factor)))
        if next != clockZoomScale { clockZoomScale = next }
    }

    private var clockMagnifyGesture: some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.001)
            .onChanged { value in
                updateClockZoom(factor: CGFloat(value.magnification))
            }
            .onEnded { value in
                finishClockZoom(factor: CGFloat(value.magnification))
            }
    }

    private func finishClockZoom(factor: CGFloat) {
        guard let origin = clockMagnifyOrigin else {
            TaptionPlanDiagnosticsLogger.shared.record(
                "record_clock_zoom_ended_without_begin",
                fields: ["factor": String(format: "%.3f", factor)]
            )
            return
        }
        // 제스처 종료값은 프레임 게이트를 우회해 즉시 반영한다.
        let next = min(4, max(1, origin * max(0.01, factor)))
        if next != clockZoomScale { clockZoomScale = next }
        clockMagnifyOrigin = nil
        lastClockZoomRenderUptime = 0
        if clockZoomScale < Self.clockLinearThreshold {
            clockZoomScale = 1
        }
        TaptionPlanDiagnosticsLogger.shared.record(
            "record_clock_zoom_ended",
            fields: [
                "factor": String(format: "%.3f", factor),
                "scale": String(format: "%.3f", clockZoomScale),
                "linear": String(clockZoomScale >= Self.clockLinearThreshold),
            ]
        )
    }

    private func resetClockZoom() {
        clockMagnifyOrigin = nil
        lastClockZoomRenderUptime = 0
        if clockZoomScale != 1 { clockZoomScale = 1 }
    }

    /// 짚어 둔 조각. 범례에서 고른 경우에는 그 이름의 첫 조각을 짚는다.
    private var highlightedPhaseArc: RecordClockDetailArc? {
        guard case .phase(let id, _) = clockHighlight else { return nil }
        return content.phaseRing?.arcs.first { $0.id == id }
    }

    private func playbackContext(
        at fraction: Double,
        in rings: [RecordClockDetailRing]
    ) -> PlaybackContextReadout? {
        func latestToken(for kind: RecordClockDetailKind) -> String? {
            rings
                .filter { $0.kind == kind }
                .flatMap(\.arcs)
                .filter { $0.startFraction <= fraction + 0.0001 }
                .max { $0.startFraction < $1.startFraction }?
                .token
        }
        let readout = PlaybackContextReadout(
            weatherToken: latestToken(for: .weather),
            locationToken: latestToken(for: .location)
        )
        return readout.isEmpty ? nil : readout
    }

    private func currentContextReadout() -> PlaybackContextReadout? {
        let now = Date.now
        let weatherToken = model.snapshot.weather
            .filter { $0.observedAt <= now }
            .max { $0.observedAt < $1.observedAt }
            .map(WeatherClockToken.make)
        let locationToken = model.snapshot.places
            .filter { $0.span.start <= now }
            .max { $0.span.start < $1.span.start }
            .map { stay in
                stay.floor.map { floor in
                    stay.displayName + " · " + String(floor) + "층"
                } ?? stay.displayName
            }
        let readout = PlaybackContextReadout(
            weatherToken: weatherToken,
            locationToken: locationToken
        )
        return readout.isEmpty ? nil : readout
    }

    private func playbackContextView(
        _ readout: PlaybackContextReadout
    ) -> some View {
        VStack(spacing: 2) {
            if let token = readout.weatherToken {
                playbackWeatherText(token)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            if let token = readout.locationToken {
                Text(detailName(.location, token: token))
                    .font(.taption(size: 7, weight: .medium))
                    .foregroundStyle(Color.tpInk)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.white.opacity(0.96), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.tpLine.opacity(0.7), lineWidth: 0.8)
        }
    }

    private func playbackWeatherText(_ token: String) -> Text {
        guard let parts = WeatherClockToken.compactParts(token) else {
            return Text(token)
                .font(.taption(size: 7, weight: .medium))
                .foregroundStyle(Color.tpInk)
        }
        return Text(parts.weather)
            .font(.system(size: 8))
            .foregroundStyle(Color.tpInk)
            + Text(" \(parts.temperature)°")
                .font(.taption(size: 7, weight: .semibold))
                .foregroundStyle(Color.tpInk)
            + Text(" \(parts.air)")
                .font(.system(size: 5))
                .foregroundStyle(Color.tpInk)
    }

    /// 원형 띠를 짚으면 빠른 활동 변경 메뉴를 연다. 재생 단추가 이 층 위에
    /// 덮여 있어 누르기를 가로채지 않는다.
    private var clockTapLayer: some View {
        GeometryReader { proxy in
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { location in
                    openRecordEditor(at: location, in: proxy.size)
                }
        }
        .accessibilityHidden(true)
    }

    private func openRecordEditor(at location: CGPoint, in size: CGSize) {
        let side = min(size.width, size.height)
        let outer = side / 2 - 24
        let dx = location.x - size.width / 2
        let dy = location.y - size.height / 2
        let distance = sqrt(dx * dx + dy * dy)
        guard let tappedBand = CircularClockTapBand.resolve(
            distance: Double(distance),
            outerRadius: Double(outer),
            phaseBandWidth: Double(Self.phaseBandWidth),
            bandGap: Double(Self.bandGap),
            activityBandWidth: Double(Self.clockBandWidth)
        ) else {
            clearClockHighlight()
            return
        }
        var fraction = (Angle(radians: atan2(dy, dx)).degrees + 90) / 360
        fraction -= floor(fraction)

        if tappedBand == .phase {
            if let selection = recordForRing(
                at: fraction,
                categoryID: nil
            ) {
                openRecord(selection)
            } else if !openUnconfirmedEditor(
                at: fraction,
                categoryID: nil
            ) {
                clearClockHighlight()
            }
            return
        }

        let categoryID = content.rings.first {
            $0.arcs.contains {
                $0.startFraction <= fraction && fraction < $0.endFraction
            }
        }?.categoryID
        if let selection = recordForRing(
            at: fraction,
            categoryID: categoryID
        ) {
            openRecord(selection)
        } else if !openUnconfirmedEditor(
            at: fraction,
            categoryID: categoryID
        ) {
            clearClockHighlight()
        }
    }

    private func openRecord(_ selection: ReviewRecordSelection) {
        clearClockHighlight()
        let record = selection.record
        let next = ReviewQuickActivitySelection(
            recordID: record.id,
            displayedSpan: selection.displayedSpan
        )
        guard quickActivitySelection?.id != next.id else { return }
        quickActivitySelection = next
    }

    @discardableResult
    private func openUnconfirmedEditor(
        at fraction: Double,
        categoryID: String?
    ) -> Bool {
        let unconfirmedID = ReviewCoverageEngine.unconfirmedCategoryID
        guard categoryID == nil || categoryID == unconfirmedID,
              let arc = content.rings
                .first(where: { $0.categoryID == unconfirmedID })?
                .arcs.first(where: {
                    $0.startFraction <= fraction && fraction < $0.endFraction
                }) else {
            return false
        }
        clearClockHighlight()
        unconfirmedSelection = ReviewUnconfirmedSelection(
            span: RecordClockEngine.span(of: arc, in: content.period)
        )
        return true
    }

    private func recordForRing(
        at fraction: Double,
        categoryID: String?
    ) -> ReviewRecordSelection? {
        let span = content.period
        let date = span.start.addingTimeInterval(span.duration * fraction)
        let now = Date.now
        let rendered = content.displayActuals.filter { actual in
            guard let visible = actual.span(asOf: now)
                .intersection(with: span), visible.duration > 0 else {
                return false
            }
            if let categoryID,
               ActualRecordCategoryResolver.categoryID(for: actual) != categoryID {
                return false
            }
            return visible.contains(date)
        }

        guard let displayed = rendered.min(by: {
            $0.span(asOf: now).duration < $1.span(asOf: now).duration
        }), let displayedSpan = displayed.span(asOf: now)
            .intersection(with: span) else {
            return nil
        }
        if let source = model.snapshot.actuals.first(where: {
            $0.id == displayed.id
        }) {
            return ReviewRecordSelection(
                record: source,
                displayedSpan: displayedSpan
            )
        }

        // Canonical travel and overlap remainders are display-only records.
        // Resolve them back to the measured record at the same instant so a
        // visible arc never silently loses its editor tap.
        let sourceCandidates = model.snapshot.actuals.filter { actual in
            guard let visible = actual.span(asOf: now)
                .intersection(with: span), visible.duration > 0,
                visible.contains(date),
                ActualRecordCategoryResolver.categoryID(for: actual)
                    == ActualRecordCategoryResolver.categoryID(for: displayed)
            else { return false }
            if let chunkID = displayed.sensorChunkID,
               actual.sensorChunkID != chunkID {
                return false
            }
            if let behavior = displayed.behavior, actual.behavior != behavior {
                return false
            }
            return true
        }
        guard let source = sourceCandidates.min(by: {
            let leftSourceRank = $0.source == displayed.source ? 0 : 1
            let rightSourceRank = $1.source == displayed.source ? 0 : 1
            if leftSourceRank != rightSourceRank {
                return leftSourceRank < rightSourceRank
            }
            let leftCreated = abs(
                $0.createdAt.timeIntervalSince(displayed.createdAt)
            )
            let rightCreated = abs(
                $1.createdAt.timeIntervalSince(displayed.createdAt)
            )
            if leftCreated != rightCreated {
                return leftCreated < rightCreated
            }
            return $0.span(asOf: now).duration
                < $1.span(asOf: now).duration
        }) else {
            return nil
        }
        return ReviewRecordSelection(
            record: source,
            displayedSpan: displayedSpan
        )
    }

    private var playControl: some View {
        Button {
            toggleClockPlayback()
        } label: {
            Image(systemName: playStartedAt == nil ? "play.fill" : "pause.fill")
                .font(.taption(size: 14, weight: .bold))
                .foregroundStyle(Color.tpProjectDark)
                .frame(
                    width: Self.clockButtonSize,
                    height: Self.clockButtonSize
                )
                .background(Color.white, in: Circle())
                .overlay(Circle().stroke(Color.tpLine, lineWidth: 0.8))
        }
        .buttonStyle(.plain)
        .disabled(
            playStartedAt == nil
                && RecordClockEngine.playbackEndFraction(
                    in: content.period,
                    asOf: Date.now
                ) == 0
        )
        .accessibilityLabel(playStartedAt == nil ? "하루 기록 재생" : "재생 멈춤")
    }

    private func toggleClockPlayback() {
        clearClockHighlight()
        let now = Date.now
        if playStartedAt != nil {
            if let fraction = clockPlaybackProgress(at: now) {
                setManualPlayhead(fraction)
            }
            playStartedAt = nil
            return
        }
        guard RecordClockEngine.playbackEndFraction(
            in: content.period,
            asOf: now
        ) > 0 else { return }
        clearManualPlayhead()
        if linearPlayheadFraction != 0 { linearPlayheadFraction = 0 }
        playStartedAt = now
    }

    /// 옆으로 넘겨 날짜를 옮긴다. 끄는 동안에는 아무것도 다시 그리지 않고
    /// 손을 뗄 때 한 번만 반영한다.
    private var dateSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onEnded { value in
                guard !circularPlayheadTracker.isDragging else { return }
                guard let step = RecordClockEngine.swipeStep(
                    width: value.translation.width,
                    height: value.translation.height
                ) else {
                    return
                }
                playStartedAt = nil
                clearManualPlayhead()
                clearClockHighlight()
                model.shiftReviewDate(by: step)
            }
    }

    private func drawClock(
        context: GraphicsContext,
        size: CGSize,
        rings: [RecordClockRing],
        phaseRing: RecordClockDetailRing?,
        pinnedPhaseArc: RecordClockDetailArc?,
        activityRings: [RecordClockDetailRing],
        highlight: ReviewClockHighlight?,
        progress: Double?,
        span: TimeSpan,
        nowFraction: Double?
    ) {
        let side = min(size.width, size.height)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        // 시각 숫자가 캔버스 밖으로 잘리지 않도록 가장자리를 비워 둔다.
        let outer = side / 2 - 24
        drawClockFace(context: context, center: center, radius: outer + 9)

        // 일과 띠는 자리를 늘 지킨다. 근거가 없는 날에도 눈금판이 하루마다
        // 커졌다 작아지지 않아야 한다.
        let revealedPhases = RecordClockEngine.detailRing(
            phaseRing,
            revealedThrough: progress
        )
        // 시각은 재생머리에 잘리지 않은 원래 조각에서 읽는다.
        let focusedPhaseArc = pinnedPhaseArc
            ?? progress.flatMap { RecordClockEngine.arc(in: phaseRing, at: $0) }
        drawPhaseRing(
            context: context,
            center: center,
            radius: outer - Self.phaseBandWidth / 2,
            ring: revealedPhases,
            focusedToken: focusedPhaseArc?.token,
            highlight: highlight,
            isPlaying: progress != nil
        )

        let radius = outer
            - Self.phaseBandWidth
            - Self.bandGap
            - Self.clockBandWidth / 2
        context.stroke(
            arcPath(center: center, radius: radius, from: 0, to: 1),
            with: .color(Color.tpLine.opacity(0.45)),
            lineWidth: Self.clockBandWidth
        )

        let revealed = RecordClockEngine.rings(
            rings,
            revealedThrough: progress
        )
        let active = progress.map {
            RecordClockEngine.categoryIDs(in: rings, at: $0)
        } ?? Set<String>()
        // 재생 중에는 재생머리가 지나는 기록만 살리고 나머지는 죽인다.
        for pass in [false, true] {
            for ring in revealed
            where active.contains(ring.categoryID) == pass {
                let tint = color(forCategoryID: ring.categoryID)
                let width = pass
                    ? Self.clockBandWidth + 6
                    : Self.clockBandWidth
                let opacity = activityOpacity(
                    categoryID: ring.categoryID,
                    highlight: highlight,
                    isPlaybackActive: progress != nil,
                    isUnderPlayhead: pass
                )
                for arc in ring.arcs {
                    context.stroke(
                        arcPath(
                            center: center,
                            radius: radius,
                            from: arc.startFraction,
                            to: arc.endFraction
                        ),
                        with: .color(tint.opacity(opacity)),
                        style: StrokeStyle(lineWidth: width, lineCap: .butt)
                    )
                }
            }
        }

        drawActivityDetailsOnBand(
            context: context,
            center: center,
            radius: radius,
            rings: RecordClockEngine.detailRings(
                activityRings,
                revealedThrough: progress
            ),
            highlight: highlight
        )

        if let progress {
            drawHand(
                context: context,
                center: center,
                radius: outer + 9,
                fraction: progress,
                tint: Color.tpNow,
                width: 1.6
            )
        } else if let nowFraction {
            drawHand(
                context: context,
                center: center,
                radius: outer + 9,
                fraction: nowFraction,
                tint: Color.tpNow,
                width: 1.6
            )
        }

        if let focusedPhaseArc {
            drawPhaseReadout(
                context: context,
                center: center,
                arc: focusedPhaseArc,
                in: span
            )
        }
    }

    /// 코어·깊은·REM 수면과 이동수단은 해당 활동 구간 위에 같은 폭으로
    /// 덮는다. 별도 상세 띠를 만들지 않아 일과·활동 두 단계만 남는다.
    private func drawActivityDetailsOnBand(
        context: GraphicsContext,
        center: CGPoint,
        radius: CGFloat,
        rings: [RecordClockDetailRing],
        highlight: ReviewClockHighlight?
    ) {
        for ring in rings {
            for arc in ring.arcs {
                context.stroke(
                    arcPath(
                        center: center,
                        radius: radius,
                        from: arc.startFraction,
                        to: arc.endFraction
                    ),
                    with: .color(
                        detailColor(ring.kind, token: arc.token)
                            .opacity(
                                activityDetailOpacity(
                                    kind: ring.kind,
                                    token: arc.token,
                                    highlight: highlight
                                )
                            )
                    ),
                    style: StrokeStyle(
                        lineWidth: Self.clockBandWidth,
                        lineCap: .butt
                    )
                )
            }
        }
    }

    private func activityOpacity(
        categoryID: String,
        highlight: ReviewClockHighlight?,
        isPlaybackActive: Bool,
        isUnderPlayhead: Bool
    ) -> Double {
        switch highlight {
        case .phase:
            return 0.1
        case .category(let selectedID):
            return categoryID == selectedID ? 1 : 0.1
        case .detail(let selection):
            return categoryID == activityCategoryID(for: selection.kind)
                ? 0.22
                : 0.08
        case nil:
            return !isPlaybackActive || isUnderPlayhead ? 1 : 0.4
        }
    }

    private func activityDetailOpacity(
        kind: RecordClockDetailKind,
        token: String,
        highlight: ReviewClockHighlight?
    ) -> Double {
        switch highlight {
        case .phase:
            return 0.1
        case .category(let selectedID):
            return activityCategoryID(for: kind) == selectedID ? 1 : 0.1
        case .detail(let selection):
            return selection.kind == kind && selection.token == token ? 1 : 0.1
        case nil:
            return 1
        }
    }

    private func activityCategoryID(
        for kind: RecordClockDetailKind?
    ) -> String? {
        switch kind {
        case .sleepStage: TimelineRowKind.sleep.rawValue
        case .travel: TimelineRowKind.movement.rawValue
        case .dayPhase, .weather, .location, nil: nil
        }
    }

    /// 가장 바깥의 일과 띠. 조각이 없어도 빈 자리는 남겨, 오감이 없던 날에도
    /// 눈금판의 크기가 흔들리지 않게 한다.
    private func drawPhaseRing(
        context: GraphicsContext,
        center: CGPoint,
        radius: CGFloat,
        ring: RecordClockDetailRing?,
        focusedToken: String?,
        highlight: ReviewClockHighlight?,
        isPlaying: Bool
    ) {
        context.stroke(
            arcPath(center: center, radius: radius, from: 0, to: 1),
            with: .color(Color.tpLine.opacity(0.35)),
            lineWidth: Self.phaseBandWidth
        )
        guard let ring else { return }
        // 짚어 둔 줄거리를 마지막에 그려 이웃 조각에 가려지지 않게 한다.
        for pass in [false, true] {
            for arc in ring.arcs where (arc.token == focusedToken) == pass {
                let isFocused = pass && focusedToken != nil
                let opacity = phaseOpacity(
                    token: arc.token,
                    focusedToken: focusedToken,
                    highlight: highlight,
                    isPlaying: isPlaying
                )
                context.stroke(
                    arcPath(
                        center: center,
                        radius: radius,
                        from: arc.startFraction,
                        to: arc.endFraction
                    ),
                    with: .color(
                        detailColor(.dayPhase, token: arc.token)
                            .opacity(opacity)
                    ),
                    style: StrokeStyle(
                        lineWidth: isFocused
                            ? Self.phaseBandWidth + 4
                            : Self.phaseBandWidth,
                        lineCap: .butt
                    )
                )
            }
        }
    }

    private func phaseOpacity(
        token: String,
        focusedToken: String?,
        highlight: ReviewClockHighlight?,
        isPlaying: Bool
    ) -> Double {
        switch highlight {
        case .phase(_, let selectedToken):
            return token == selectedToken ? 1 : 0.12
        case .category, .detail:
            return 0.12
        case nil:
            return isPlaying && token != focusedToken ? 0.3 : 1
        }
    }

    /// 띠가 좁아 글자를 얹을 수 없으므로, 짚었거나 재생머리가 지나는 줄거리의
    /// 이름과 그 시작·끝 시각만 가운데 단추 위에 띄운다.
    private func drawPhaseReadout(
        context: GraphicsContext,
        center: CGPoint,
        arc: RecordClockDetailArc,
        in span: TimeSpan
    ) {
        let tint = detailColor(.dayPhase, token: arc.token)
        let name = Text(detailName(.dayPhase, token: arc.token))
            .font(.taption(size: 9, weight: .bold))
            .foregroundStyle(tint)
        let withTimes = name
            + Text(
                " " + RecordClockEngine.timeRangeText(
                    RecordClockEngine.span(of: arc, in: span)
                )
            )
            .font(.taption(size: 7.5))
            .foregroundStyle(Color.tpSecondary)

        let label = context.resolve(withTimes)
        let size = label.measure(in: CGSize(width: 240, height: 40))
        let top = -Self.clockButtonSize / 2 - size.height - 8
        let box = CGRect(
            x: center.x - size.width / 2 - 8,
            y: center.y + top,
            width: size.width + 16,
            height: size.height + 4
        )
        let pill = Path(roundedRect: box, cornerRadius: box.height / 2)
        context.fill(pill, with: .color(.white))
        context.stroke(pill, with: .color(tint.opacity(0.5)), lineWidth: 0.9)
        context.draw(label, at: CGPoint(x: box.midX, y: box.midY))
    }

    private func detailColor(
        _ kind: RecordClockDetailKind,
        token: String
    ) -> Color {
        RecordTimelinePalette.detailColor(kind, token: token)
    }

    private func detailName(
        _ kind: RecordClockDetailKind,
        token: String
    ) -> String {
        switch kind {
        case .dayPhase:
            return DayPhase(rawValue: token)?.title ?? token
        case .sleepStage:
            return SleepStage(rawValue: token)?.displayName ?? token
        case .travel:
            return TravelMode(rawValue: token).map(MovementPresentation.title)
                ?? token
        case .weather:
            return WeatherClockToken.displayName(token)
        case .location:
            return token
        }
    }

    /// 일과 띠의 색이 무엇을 뜻하는지 적는다. 카테고리 범례처럼 눌러서 하나만
    /// 살릴 수 있고, 그때 눈금판 가운데에도 같은 이름이 뜬다.
    private func phaseLegend(_ ring: RecordClockDetailRing) -> some View {
        ChipFlowLayout(spacing: 5) {
            Text("일과")
                .font(.taption(size: 8.5, weight: .bold))
                .foregroundStyle(Color.tpSecondary)
                .padding(.vertical, 4)
            ForEach(detailTokens(of: ring), id: \.self) { token in
                let isSelected = highlightedPhaseToken == token
                Button {
                    guard let arc = ring.arcs.first(where: { $0.token == token })
                    else { return }
                    let next = ReviewClockHighlight.phase(
                        arcID: arc.id,
                        token: token
                    )
                    clockHighlight = clockHighlight == next ? nil : next
                } label: {
                    HStack(spacing: 4) {
                        Capsule()
                            .fill(detailColor(.dayPhase, token: token))
                            .frame(width: 10, height: 6)
                        Text(detailName(.dayPhase, token: token))
                            .font(
                                .taption(
                                    size: 8.5,
                                    weight: isSelected
                                        ? .bold
                                        : .regular
                                )
                            )
                            .foregroundStyle(Color.tpInk)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(
                        isSelected
                            ? detailColor(.dayPhase, token: token).opacity(0.16)
                            : Color(red: 0.95, green: 0.95, blue: 0.96),
                        in: Capsule()
                    )
                }
                .opacity(legendOpacity(isSelected: isSelected))
                .buttonStyle(.plain)
                .accessibilityLabel(detailName(.dayPhase, token: token))
                .accessibilityAddTraits(
                    isSelected ? [.isSelected] : []
                )
            }
        }
    }

    private func detailTokens(of ring: RecordClockDetailRing) -> [String] {
        var seen = Set<String>()
        return ring.arcs.map(\.token).filter { seen.insert($0).inserted }
    }

    private func arcPath(
        center: CGPoint,
        radius: CGFloat,
        from: Double,
        to: Double
    ) -> Path {
        Path {
            $0.addArc(
                center: center,
                radius: radius,
                startAngle: clockAngle(from),
                endAngle: clockAngle(max(to, from + 0.0018)),
                clockwise: false
            )
        }
    }

    private func drawHand(
        context: GraphicsContext,
        center: CGPoint,
        radius: CGFloat,
        fraction: Double,
        tint: Color,
        width: CGFloat
    ) {
        let angle = clockAngle(fraction)
        // 가운데 재생 단추를 가리지 않도록 바늘은 단추 밖에서 시작한다.
        let inner = point(
            center: center,
            radius: Self.clockButtonSize / 2 + 5,
            angle: angle
        )
        let tip = point(center: center, radius: radius, angle: angle)
        context.stroke(
            Path {
                $0.move(to: inner)
                $0.addLine(to: tip)
            },
            with: .color(tint),
            style: StrokeStyle(lineWidth: width, lineCap: .round)
        )
        context.fill(
            Path(
                ellipseIn: CGRect(
                    x: tip.x - 3,
                    y: tip.y - 3,
                    width: 6,
                    height: 6
                )
            ),
            with: .color(tint)
        )
    }

    private func drawClockFace(
        context: GraphicsContext,
        center: CGPoint,
        radius: CGFloat
    ) {
        for hour in RecordClockEngine.labeledHours {
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
            let label = context.resolve(
                Text(String(format: "%02d", hour))
                    .font(
                        .taption(
                            size: isMajor ? 8 : 6.5,
                            weight: isMajor ? .bold : .medium
                        )
                    )
                    .foregroundStyle(
                        Color.tpSecondary.opacity(isMajor ? 1 : 0.82)
                    )
            )
            context.draw(
                label,
                at: point(center: center, radius: radius + 7, angle: angle)
            )
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

    private var barChart: some View {
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

    private func selectChartBucket(
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
    private func barOpacity(
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

    private var barUnit: Calendar.Component {
        model.reviewScale == .year ? .month : .day
    }

    private var barMaximumHours: Double {
        switch model.reviewScale {
        case .week, .month: 24
        case .year: RecordChartEngine.maxTotalHours(content.chartBuckets)
        case .day: 24
        }
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

    private func activityDetailKind(
        for categoryID: String
    ) -> RecordClockDetailKind? {
        switch categoryID {
        case TimelineRowKind.sleep.rawValue: .sleepStage
        case TimelineRowKind.movement.rawValue: .travel
        default: nil
        }
    }

    private func activityTokens(
        for kind: RecordClockDetailKind
    ) -> [String] {
        content.activityRings
            .filter { $0.kind == kind }
            .flatMap(detailTokens)
    }

    private func categoryLegendChip(_ group: RecordCategoryGroup) -> some View {
        let isSelected = highlightedCategoryID == group.id
        return Button {
            let next = ReviewClockHighlight.category(group.id)
            clockHighlight = clockHighlight == next ? nil : next
        } label: {
            HStack(spacing: 4) {
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
                    : Color(red: 0.95, green: 0.95, blue: 0.96),
                in: Capsule()
            )
        }
        .opacity(legendOpacity(isSelected: isSelected))
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func activityDetailLegendChip(
        _ kind: RecordClockDetailKind,
        token: String
    ) -> some View {
        let selection = ReviewDetailSelection(kind: kind, token: token)
        let isSelected = highlightedDetail == selection
        return Button {
            let next = ReviewClockHighlight.detail(selection)
            clockHighlight = clockHighlight == next ? nil : next
        } label: {
            HStack(spacing: 4) {
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
                    : Color(red: 0.95, green: 0.95, blue: 0.96),
                in: Capsule()
            )
        }
        .opacity(legendOpacity(isSelected: isSelected))
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func phaseSummaryLegendChip(_ id: String) -> some View {
        let phase = DayPhase(rawValue: id)
        let tint = detailColor(.dayPhase, token: id)
        let isSelected = highlightedCategoryID == id
        return Button {
            let next = ReviewClockHighlight.category(id)
            clockHighlight = clockHighlight == next ? nil : next
        } label: {
            HStack(spacing: 4) {
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
                    : Color(red: 0.95, green: 0.95, blue: 0.96),
                in: Capsule()
            )
        }
        .opacity(legendOpacity(isSelected: isSelected))
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func legendOpacity(isSelected: Bool) -> Double {
        clockHighlight == nil || isSelected ? 1 : 0.42
    }

    // MARK: - 메모

    private var memoBreakdownCard: some View {
        let memos = content.contexts.filter { $0.symbolName == "note.text" }

        return VStack(alignment: .leading, spacing: 8) {
            Label("메모", systemImage: "note.text")
                .font(.taption(size: 11, weight: .bold))

            if memos.isEmpty {
                Text("이 기간에 작성된 메모가 없습니다.")
                    .font(.taption(size: 10.5))
                    .foregroundStyle(Color.tpSecondary)
            } else {
                ForEach(memos) { memo in
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: "note.text")
                            .font(.taption(size: 11))
                            .foregroundStyle(Color.tpStudyDark)
                            .frame(width: 14)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(memo.text)
                                .font(.taption(size: 10, weight: .medium))
                                .lineLimit(3)
                            Text(
                                memo.date.formatted(
                                    date: .omitted,
                                    time: .shortened
                                )
                            )
                            .font(.taption(size: 8.5))
                            .foregroundStyle(Color.tpSecondary)
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
        let groups = hierarchyGroups
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Label("실제 기록", systemImage: "checkmark.circle")
                    .font(.taption(size: 11, weight: .bold))
                Spacer()
                Text(
                    model.reviewScale == .day || model.reviewScale == .week
                        ? "\(groups.count)개 일과 · \(childCount)개 상세활동"
                        : "\(childCount)개 항목"
                )
                    .font(.taption(size: 9))
                    .foregroundStyle(Color.tpSecondary)
            }

            if groups.isEmpty {
                Text("이 기간에 저장된 실제 데이터가 없습니다.")
                    .font(.taption(size: 10.5))
                    .foregroundStyle(Color.tpSecondary)
            } else {
                ForEach(groups) { group in
                    categorySection(group)
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
        hierarchyGroups.reduce(0) { $0 + $1.children.count }
    }

    private var hierarchyGroups: [RecordCategoryGroup] {
        model.reviewScale == .day || model.reviewScale == .week
            ? content.phaseGroups
            : content.groups
    }

    @ViewBuilder
    private func categorySection(_ group: RecordCategoryGroup) -> some View {
        let isExpanded = !collapsedGroupIDs.contains(group.id)
        VStack(alignment: .leading, spacing: 2) {
            Button {
                clearClockHighlight()
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
                    Text(displayedGroupName(group))
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
            clearClockHighlight()
            model.detail = .actual(child.recordID)
        } label: {
            HStack(spacing: 7) {
                if let tokenData = appUsageTokenData(for: child, in: group) {
                    // 어플 기록만 시스템이 그리는 실제 앱 이름·아이콘을 쓴다.
                    AppUsageNameLabel(tokenData: tokenData, size: 10)
                } else {
                    HStack(spacing: 5) {
                        Image(systemName: childSymbolName(child, in: group))
                            .font(.taption(size: 9, weight: .semibold))
                            .foregroundStyle(color(forCategoryID: group.id))
                            .frame(width: 14)
                        Text(child.title)
                            .font(.taption(size: 10, weight: .medium))
                            .lineLimit(1)
                    }
                }
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
                Text(DurationText.koreanAtLeastAMinute(child.duration))
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
            "\(displayedGroupName(group)) \(child.title) \(DurationText.koreanAtLeastAMinute(child.duration))"
        )
    }

    private func childSymbolName(
        _ child: RecordGroupChild,
        in group: RecordCategoryGroup
    ) -> String {
        if let actual = model.snapshot.actuals.first(where: {
            $0.id == child.recordID
        }) {
            if let behavior = actual.behavior,
               let kind = WatchBehaviorKind.fromModelLabel(behavior) {
                return kind.systemImage
            }
            return ActivityCorrectionCatalog.activitySystemImage(
                title: actual.title,
                behavior: actual.behavior,
                categoryID: group.id
            )
        }
        return ActivityCorrectionCatalog.activitySystemImage(
            title: child.title,
            behavior: nil,
            categoryID: group.id
        )
    }

    private func displayedGroupName(_ group: RecordCategoryGroup) -> String {
        group.id == "activity" ? "상세활동" : group.name
    }

    private func appUsageTokenData(
        for child: RecordGroupChild,
        in group: RecordCategoryGroup
    ) -> Data? {
        guard group.id == "appUsage" else { return nil }
        let data = model.appUsageTokenIndex[child.recordID]
        return AppUsageNameLabel.canRender(data) ? data : nil
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
        let contexts = content.contexts.filter {
            $0.symbolName != "note.text"
        }
        return VStack(alignment: .leading, spacing: 7) {
            Text("이 기간을 설명한 기록")
                .font(.taption(size: 11, weight: .bold))
            if contexts.isEmpty {
                contextLine(
                    "tray",
                    "사진·날씨가 연결되면 이번 기간의 맥락을 보여드립니다."
                )
            } else {
                ForEach(contexts) { context in
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
            date: model.selectedDate,
            selectedBucketIDs: selectedBucketIDs,
            selectedChartBucketID: selectedChartBucketID,
            healthRefreshedAt: model.lastHealthRefreshAt
        )
    }

    private func rebuildContent() {
        let engine = ReviewEngine()
        let now = Date.now
        // 화면(원형·막대·목록)과 합계가 모두 이 한 값을 읽는다. 수면과 겹친
        // 휴식·생활을 여기서 한 번만 덜어 내야 보이는 시간과 합계가 맞는다.
        let actuals = RestSleepDisplayEngine.visibleActuals(
            MovementDisplayEngine.reviewActuals(
                model.snapshot.actuals,
                travel: model.snapshot.travel,
                calendarEvents: model.snapshot.calendarEvents,
                asOf: now
            ),
            asOf: now
        )
        let level = model.reviewScale.timelineLevel
        let period = engine.aggregation.interval(
            for: level,
            containing: model.selectedDate
        )
        let pickable = ReviewSelectionEngine.buckets(
            for: level,
            in: period,
            calendar: engine.aggregation.calendar
        )
        // 다른 기간의 칸을 고른 채로 넘어왔다면 버린다. 남은 칸이 없으면
        // 아래에서 기간 전체로 돌아간다.
        let selected = selectedBucketIDs.intersection(
            Set(pickable.map(\.id))
        )
        if selected != selectedBucketIDs { selectedBucketIDs = selected }

        let phaseActuals = DayPhaseEvidenceEngine.records(
            from: model.snapshot.actuals,
            intersecting: period,
            asOf: now
        )
        let placeKinds = FrequentPlaceResolutionEngine().kindsByPlaceKey(
            model.snapshot.settings.frequentPlaces
        )
        let chartBuckets = model.reviewScale == .day
            ? []
            : RecordChartEngine.phaseBuckets(
                actuals: phaseActuals,
                travel: model.snapshot.travel,
                stays: model.snapshot.places,
                placeKinds: placeKinds,
                in: period,
                unit: model.reviewScale == .year ? .month : .day,
                calendar: engine.aggregation.calendar,
                asOf: now
            )
        let selectedChartSpan = ReviewSelectionEngine.chartSpan(
            selectedChartBucketID,
            buckets: chartBuckets
        )
        if selectedChartBucketID != nil, selectedChartSpan == nil {
            selectedChartBucketID = nil
        }

        // 막대를 직접 골랐으면 그 하루·월이 헤더의 큰 구간 선택보다 우선한다.
        let bucketSpans = ReviewSelectionEngine.spans(
            period: period,
            buckets: pickable,
            selectedIDs: selected
        )
        let spans = selectedChartSpan.map { [$0] } ?? bucketSpans
        let displayActuals = ReviewCoverageEngine.records(
            actuals: actuals,
            in: spans,
            asOf: now
        )
        let report = engine.report(
            over: spans,
            plans: model.snapshot.plans,
            actuals: displayActuals,
            weather: model.snapshot.weather,
            photos: model.snapshot.photos,
            memos: model.snapshot.memos,
            asOf: now
        )

        var rings: [RecordClockRing] = []
        var phaseRing: RecordClockDetailRing?
        var activityRings: [RecordClockDetailRing] = []
        var contextRings: [RecordClockDetailRing] = []
        var phaseGroups: [RecordCategoryGroup] = []
        var phaseDurations = RecordChartEngine.categoryDurations(
            in: chartBuckets
        )
        var selectedChartBucketIDs: Set<String> = []
        if model.reviewScale == .day, let day = spans.first {
            rings = RecordChartEngine.clockRings(
                actuals: displayActuals,
                in: day,
                asOf: now
            )
            let dayPhases = DayPhaseEngine.completePhases(
                actuals: phaseActuals,
                travel: model.snapshot.travel,
                stays: model.snapshot.places,
                placeKinds: placeKinds,
                in: day,
                asOf: now
            )
            phaseDurations = DayPhaseEngine.categoryDurations(dayPhases)
            phaseRing = RecordClockDetailEngine.phaseRing(
                actuals: phaseActuals,
                travel: model.snapshot.travel,
                stays: model.snapshot.places,
                placeKinds: placeKinds,
                in: day,
                asOf: now
            )
            phaseGroups = ActualRecordGroupingEngine.phaseGroups(
                phases: dayPhases,
                actuals: displayActuals,
                categories: model.snapshot.categories,
                asOf: now
            )
            activityRings = RecordClockDetailEngine.activityRings(
                sleepSessions: model.sleepSessions,
                travel: model.snapshot.travel,
                in: day
            )
            contextRings = [
                RecordClockDetailEngine.weatherRing(
                    contexts: model.snapshot.weather,
                    in: day,
                    asOf: now
                ),
                RecordClockDetailEngine.locationRing(
                    stays: model.snapshot.places,
                    in: day,
                    asOf: now
                ),
            ].compactMap { $0 }
        } else if model.reviewScale == .week {
            // 주 보기 역시 하루 단위로 완성한 일과를 부모로 사용한다.
            // 선택한 날짜가 있으면 그 날짜만, 없으면 주 전체를 계층으로 묶는다.
            let phases = spans.flatMap { span in
                DayPhaseEngine.completePhasesAcrossDays(
                    actuals: phaseActuals,
                    travel: model.snapshot.travel,
                    stays: model.snapshot.places,
                    placeKinds: placeKinds,
                    in: span,
                    calendar: engine.aggregation.calendar,
                    asOf: now
                )
            }
            phaseGroups = ActualRecordGroupingEngine.phaseGroups(
                phases: phases,
                actuals: displayActuals,
                categories: model.snapshot.categories,
                asOf: now
            )
            if let selectedChartBucketID, selectedChartSpan != nil {
                selectedChartBucketIDs = [selectedChartBucketID]
            } else if !selected.isEmpty {
                selectedChartBucketIDs = Set(
                    chartBuckets
                        .filter { bucket in
                            spans.contains {
                                $0.intersection(with: bucket.span) != nil
                            }
                        }
                        .map(\.id)
                )
            }
        } else {
            if let selectedChartBucketID, selectedChartSpan != nil {
                selectedChartBucketIDs = [selectedChartBucketID]
            } else if !selected.isEmpty {
                selectedChartBucketIDs = Set(
                    chartBuckets
                        .filter { bucket in
                            spans.contains {
                                $0.intersection(with: bucket.span) != nil
                            }
                        }
                        .map(\.id)
                )
            }
        }

        // 보고 있는 기간이 바뀌면 재생하던 하루와 수동 위치가 사라진다.
        if content.period != period {
            clearManualPlayhead()
        }
        if content.period != period || model.reviewScale != .day {
            playStartedAt = nil
        }
        let groups = ActualRecordGroupingEngine.groups(
            actuals: displayActuals,
            in: spans,
            categories: model.snapshot.categories,
            asOf: now
        )
        let hierarchyGroups = model.reviewScale == .day || model.reviewScale == .week
            ? phaseGroups
            : groups
        let groupIDs = Set(hierarchyGroups.map(\.id))
        let collapsesAllGroups = content.spans.isEmpty
            || content.period != period
        content = ReviewContent(
            period: period,
            spans: spans,
            pickableBuckets: pickable,
            selectedBucketCount: selectedChartSpan == nil ? selected.count : 1,
            plannedCategories: report.categories,
            contexts: report.contexts,
            groups: groups,
            displayActuals: displayActuals,
            phaseGroups: phaseGroups,
            rings: rings,
            phaseRing: phaseRing,
            activityRings: activityRings,
            contextRings: contextRings,
            phaseDurations: phaseDurations,
            chartBuckets: chartBuckets,
            selectedChartBucketIDs: selectedChartBucketIDs
        )
        collapsedGroupIDs = collapsesAllGroups
            ? groupIDs
            : collapsedGroupIDs.intersection(groupIDs)
        let legendIDs = model.reviewScale == .day
            ? Set(groups.map(\.id))
            : Set(phaseDurations.map(\.categoryID))
        switch clockHighlight {
        case .phase(let arcID, let token):
            if phaseRing?.arcs.contains(where: {
                $0.id == arcID && $0.token == token
            }) != true {
                clearClockHighlight()
            }
        case .category(let id):
            if !legendIDs.contains(id) { clearClockHighlight() }
        case .detail(let selection):
            if !activityRings.contains(where: {
                $0.kind == selection.kind
                    && $0.arcs.contains(where: { $0.token == selection.token })
            }) {
                clearClockHighlight()
            }
        case nil:
            break
        }
    }

    // MARK: - 표기

    private func periodText(_ span: TimeSpan) -> String {
        let period = span.start.formatted(.dateTime.month().day())
            + " – "
            + span.end.addingTimeInterval(-1).formatted(.dateTime.month().day())
        guard content.selectedBucketCount > 0 else { return period }
        return "\(period) · \(content.selectedBucketCount)칸"
    }

    private func categoryName(_ id: String) -> String {
        if id == ReviewCoverageEngine.unconfirmedCategoryID { return "미확인" }
        return model.snapshot.categories.first { $0.id == id }?.name
            ?? TimelineRowKind.title(forCategoryID: id)
            ?? PlanCategory(categoryID: id).rawValue
    }

    private func symbolName(_ group: RecordCategoryGroup) -> String {
        if group.id == ReviewCoverageEngine.unconfirmedCategoryID {
            return "questionmark.circle"
        }
        return TimelineRowKind(categoryID: group.id)?.systemImage
            ?? group.icon?.systemImage
            ?? PlanCategory(categoryID: group.id).systemImage
    }

    private func color(forCategoryID id: String) -> Color {
        RecordTimelinePalette.categoryColor(
            id,
            fallbackHex: content.groups.first { $0.id == id }?.colorHex
        )
    }
}

struct UnconfirmedRecordDetailView: View {
    @Bindable var model: AppModel
    let span: TimeSpan
    @State private var isEditorPresented = true

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.tpBackground)
            .sheet(
                isPresented: $isEditorPresented,
                onDismiss: dismissDetail
            ) {
                ActivityCorrectionSheet(
                    model: model,
                    unconfirmedSpan: span,
                    showsQuickMenu: true
                )
            }
    }

    private func dismissDetail() {
        guard model.detail == .unconfirmedEditor(span) else { return }
        model.detail = nil
    }
}

struct ActualRecordDetailView: View {
    @Bindable var model: AppModel
    let recordID: UUID
    let correctionSpan: TimeSpan?
    let opensEditor: Bool
    @State private var isActivityPickerPresented = false
    @State private var focusedRecordID: UUID
    @State private var didOpenEditor = false

    init(
        model: AppModel,
        recordID: UUID,
        correctionSpan: TimeSpan? = nil,
        opensEditor: Bool = false
    ) {
        self.model = model
        self.recordID = recordID
        self.correctionSpan = correctionSpan
        self.opensEditor = opensEditor
        _focusedRecordID = State(initialValue: recordID)
    }

    private var record: ActualRecord? {
        guard var value = detailRecords.first(where: {
            $0.id == focusedRecordID
        }) else {
            return nil
        }
        if let focusedCorrectionSpan {
            value.startedAt = focusedCorrectionSpan.start
            value.endedAt = focusedCorrectionSpan.end
        }
        return value
    }

    private var focusedCorrectionSpan: TimeSpan? {
        focusedRecordID == recordID ? correctionSpan : nil
    }

    private var detailRecords: [ActualRecord] {
        MovementDisplayEngine.reviewActuals(
            model.snapshot.actuals,
            travel: model.snapshot.travel,
            calendarEvents: model.snapshot.calendarEvents
        )
    }

    private var classifiedRecords: [ActualRecord] {
        let calendar = Calendar.autoupdatingCurrent
        guard let anchor = detailRecords.first(where: {
            $0.id == focusedRecordID
        }) else { return [] }
        return detailRecords
            .filter {
                calendar.isDate($0.startedAt, inSameDayAs: anchor.startedAt)
                    && $0.span(asOf: Date.now).duration > 0
            }
            .sorted { $0.startedAt == $1.startedAt
                ? $0.id.uuidString < $1.id.uuidString
                : $0.startedAt < $1.startedAt }
    }

    private var focusedRecordIndex: Int? {
        classifiedRecords.firstIndex { $0.id == focusedRecordID }
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
                    VStack(alignment: .leading, spacing: 10) {
                        recordPager
                        detailContent(record)
                    }
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
            .simultaneousGesture(recordSwipeGesture)
        }
        .sheet(isPresented: $isActivityPickerPresented) {
            ActivityCorrectionSheet(
                model: model,
                recordID: focusedRecordID,
                displayedSpan: focusedCorrectionSpan,
                showsQuickMenu: true
            )
        }
        .onAppear {
            guard opensEditor,
                  !didOpenEditor,
                  isStoredRecord(focusedRecordID) else { return }
            didOpenEditor = true
            isActivityPickerPresented = true
        }
    }

    private var recordPager: some View {
        guard let index = focusedRecordIndex, classifiedRecords.count > 1
        else { return AnyView(EmptyView()) }

        return AnyView(
            HStack(spacing: 8) {
                pagerButton("chevron.left", enabled: index > 0) {
                    moveRecord(by: -1)
                }
                Spacer()
                Text("분류된 기록 (index + 1) / (classifiedRecords.count)")
                    .font(.taption(size: 10, weight: .semibold))
                    .foregroundStyle(Color.tpSecondary)
                Spacer()
                pagerButton(
                    "chevron.right",
                    enabled: index + 1 < classifiedRecords.count
                ) {
                    moveRecord(by: 1)
                }
            }
            .padding(.horizontal, 4)
        )
    }

    private func pagerButton(
        _ systemImage: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.taption(size: 11, weight: .bold))
                .foregroundStyle(enabled ? Color.tpInk : Color.tpLine)
                .frame(width: 28, height: 28)
                .background(Color.white, in: Circle())
                .overlay(Circle().stroke(Color.tpLine, lineWidth: 0.7))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private var recordSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height),
                      abs(value.translation.width) >= 40 else { return }
                moveRecord(by: value.translation.width < 0 ? 1 : -1)
            }
    }

    private func moveRecord(by offset: Int) {
        guard let index = focusedRecordIndex else { return }
        let next = index + offset
        guard classifiedRecords.indices.contains(next) else { return }
        isActivityPickerPresented = false
        focusedRecordID = classifiedRecords[next].id
    }

    private func detailContent(_ record: ActualRecord) -> some View {
        let categoryID = displayCategoryID(record)
        let span = record.span(asOf: Date.now)
        return VStack(alignment: .leading, spacing: 12) {
            Button {
                if isStoredRecord(record.id) {
                    isActivityPickerPresented = true
                }
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Label(
                            displayTitle(record, categoryID: categoryID),
                            systemImage: symbolName(record, categoryID: categoryID)
                        )
                        .font(.taption(size: 17, weight: .bold))
                        .foregroundStyle(PlanCategory(categoryID: categoryID).darkColor)
                        Spacer(minLength: 4)
                        if isStoredRecord(record.id) {
                            Image(systemName: "chevron.right")
                                .font(.taption(size: 11, weight: .semibold))
                                .foregroundStyle(Color.tpSecondary)
                        }
                    }
                    applicationNameLabel(record)
                    Text("\(span.start.formatted(date: .abbreviated, time: .shortened)) – \(span.end.formatted(date: .omitted, time: .shortened))")
                        .font(.taption(size: 11))
                        .foregroundStyle(Color.tpSecondary)
                    Text(durationText(span.duration))
                        .font(.taption(size: 15, weight: .semibold))
                        .foregroundStyle(Color.tpProjectDark)
                    Text(
                        isStoredRecord(record.id)
                            ? "탭하여 상세활동·시간 수정"
                            : "센서에서 복원한 이동 기록"
                    )
                        .font(.taption(size: 9, weight: .medium))
                        .foregroundStyle(Color.tpSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 15))
            }
            .buttonStyle(.plain)

            if let travel = subwayTravel(for: record),
               let route = travel.subwayRoute {
                SubwayRouteTimelineView(route: route, span: travel.span)
            }

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
                Label("센서·건강 원본은 보존되고 표시 활동만 변경됩니다.", systemImage: "lock.fill")
                    .font(.taption(size: 9))
                    .foregroundStyle(Color.tpSecondary)
                    .padding(.horizontal, 2)
            }
        }
    }

    private func isStoredRecord(_ id: UUID) -> Bool {
        model.snapshot.actuals.contains { $0.id == id }
    }

    private func subwayTravel(for record: ActualRecord) -> TravelSegment? {
        let span = record.span(asOf: Date.now)
        return model.snapshot.travel
            .filter {
                $0.mode == .subway
                    && $0.subwayRoute != nil
                    && $0.span.intersection(with: span) != nil
            }
            .max {
                ($0.span.intersection(with: span)?.duration ?? 0)
                    < ($1.span.intersection(with: span)?.duration ?? 0)
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

struct SubwayRouteTimelineView: View {
    private struct StationNode: Identifiable {
        let id: String
        let name: String
        var lineNames: [String]
        var routeIndex: Int
        var isTransfer: Bool
    }

    let route: SubwayRoutePath
    let span: TimeSpan
    var isCompact = false

    private var nodes: [StationNode] {
        var result: [StationNode] = []
        for (index, stop) in route.stops.enumerated() {
            let normalized = normalizedStationName(stop.stationName)
            if let last = result.last,
               normalizedStationName(last.name) == normalized {
                var value = last
                if !value.lineNames.contains(stop.lineName) {
                    value.lineNames.append(stop.lineName)
                }
                value.routeIndex = index
                value.isTransfer = true
                result[result.count - 1] = value
                continue
            }
            result.append(
                StationNode(
                    id: "\(index).\(normalized).\(stop.lineName)",
                    name: stop.stationName,
                    lineNames: [stop.lineName],
                    routeIndex: index,
                    isTransfer: route.transferStationNames.contains {
                        normalizedStationName($0) == normalized
                    }
                )
            )
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: isCompact ? 6 : 9) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Label("지하철 노선", systemImage: "tram.fill")
                    .font(.taption(
                        size: isCompact ? 8 : 11,
                        weight: .bold
                    ))
                    .foregroundStyle(Color.tpProjectDark)
                Spacer(minLength: 4)
                Text(route.lineNames.joined(separator: " → "))
                    .font(.taption(
                        size: isCompact ? 6.8 : 9,
                        weight: .semibold
                    ))
                    .foregroundStyle(Color.tpSecondary)
                    .lineLimit(1)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(Array(nodes.enumerated()), id: \.element.id) { index, node in
                        stationNode(node, isLast: index == nodes.count - 1)
                    }
                }
                .padding(.horizontal, isCompact ? 2 : 4)
            }

            if !route.transferStationNames.isEmpty {
                Label(
                    route.transferStationNames
                        .map { "\(stationTitle($0)) 환승" }
                        .joined(separator: " · "),
                    systemImage: "arrow.triangle.swap"
                )
                .font(.taption(size: isCompact ? 6.8 : 9, weight: .semibold))
                .foregroundStyle(Color.tpPlaceDark)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(isCompact ? 8 : 12)
        .background(
            Color.tpProject.opacity(0.12),
            in: RoundedRectangle(cornerRadius: isCompact ? 10 : 13)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private func stationNode(
        _ node: StationNode,
        isLast: Bool
    ) -> some View {
        let width: CGFloat = isCompact ? 54 : 70
        return VStack(spacing: isCompact ? 2 : 4) {
            Text(timeText(for: node))
                .font(.taption(size: isCompact ? 6 : 8))
                .foregroundStyle(Color.tpSecondary)
            ZStack {
                if !isLast {
                    Rectangle()
                        .fill(Color.tpProjectDark.opacity(0.45))
                        .frame(width: width, height: 2)
                        .offset(x: width / 2)
                }
                Circle()
                    .fill(node.isTransfer ? Color.tpPlaceDark : Color.tpProjectDark)
                    .frame(width: isCompact ? 7 : 9, height: isCompact ? 7 : 9)
                    .overlay(
                        Circle().stroke(Color.white, lineWidth: isCompact ? 1 : 1.5)
                    )
            }
            .frame(width: width, height: isCompact ? 8 : 10)
            Text(stationTitle(node.name))
                .font(.taption(
                    size: isCompact ? 6.3 : 8.5,
                    weight: node.isTransfer ? .bold : .medium
                ))
                .foregroundStyle(node.isTransfer ? Color.tpPlaceDark : Color.tpInk)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: width)
            if node.isTransfer {
                Text("환승")
                    .font(.taption(size: isCompact ? 5.8 : 7.5, weight: .bold))
                    .foregroundStyle(Color.tpPlaceDark)
            } else {
                Text(" ")
                    .font(.taption(size: isCompact ? 5.8 : 7.5))
            }
        }
        .frame(width: width)
    }

    private func timeText(for node: StationNode) -> String {
        if node.routeIndex == 0 {
            return span.start.formatted(date: .omitted, time: .shortened)
        }
        if node.routeIndex == route.stops.count - 1 {
            return span.end.formatted(date: .omitted, time: .shortened)
        }
        return " "
    }

    private func stationTitle(_ name: String) -> String {
        name.hasSuffix("역") ? name : "\(name)역"
    }

    private func normalizedStationName(_ name: String) -> String {
        let compact = name.filter { !$0.isWhitespace }
        return compact.hasSuffix("역") ? String(compact.dropLast()) : compact
    }

    private var accessibilityText: String {
        let stationNames = nodes.map { stationTitle($0.name) }
            .joined(separator: ", ")
        return "지하철 노선 \(route.lineNames.joined(separator: "에서 ")), \(stationNames)"
    }
}

private enum ActivityCorrectionCatalog {
    static func options(
        for record: ActualRecord,
        actuals: [ActualRecord],
        customLabels: [String]
    ) -> [ActivityCorrectionOption] {
        var result: [ActivityCorrectionOption] = []
        var seen = Set<String>()
        let calendar = Calendar.autoupdatingCurrent
        let automatic = actuals
            .filter {
                guard calendar.isDate($0.startedAt, inSameDayAs: record.startedAt)
                else { return false }
                let category = ActualRecordCategoryResolver.categoryID(for: $0)
                return [
                    "activity", "movement", "sleep", "work", "study", "hobby",
                    "exercise", "rest", "routine", "food", "relationship"
                ].contains(category) || $0.id == record.id
            }
            .sorted { $0.startedAt < $1.startedAt }
        for actual in automatic {
            let option = automaticOption(for: actual)
            guard seen.insert(option.title).inserted else { continue }
            result.append(option)
        }
        for kind in WatchBehaviorKind.confirmationChoices {
            let option = option(for: kind)
            guard seen.insert(option.title).inserted else { continue }
            result.append(option)
        }
        for context in StationaryContextKind.allCases
        where context != .unknownStay {
            let option = option(for: context)
            guard seen.insert(option.title).inserted else { continue }
            result.append(option)
        }
        for label in customLabels {
            let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let option = ActivityCorrectionOption.custom(trimmed)
            guard seen.insert(option.title).inserted else { continue }
            result.append(option)
        }
        return result
    }

    static func quickOptions(
        for record: ActualRecord,
        actuals: [ActualRecord],
        customLabels: [String]
    ) -> [ActivityCorrectionOption] {
        options(
            for: record,
            actuals: actuals,
            customLabels: customLabels
        )
        .filter(ActivityQuickSelectionPolicy.isDetailedOption)
    }

    private static func automaticOption(for record: ActualRecord) -> ActivityCorrectionOption {
        if let behavior = record.behavior,
           let kind = WatchBehaviorKind.fromModelLabel(behavior) {
            return option(for: kind, automatic: true)
        }
        if let behavior = record.behavior,
           let context = StationaryContextKind(rawValue: behavior) {
            return option(for: context, automatic: true)
        }
        return ActivityCorrectionOption(
            id: "automatic.\(record.id.uuidString)",
            title: record.title.isEmpty ? "활동" : record.title,
            behavior: record.behavior,
            categoryID: record.categoryID,
            systemImage: activitySystemImage(
                title: record.title,
                behavior: record.behavior,
                categoryID: record.categoryID
            ),
            isAutomatic: true,
            isCustom: false
        )
    }

    private static func option(
        for kind: WatchBehaviorKind,
        automatic: Bool = false
    ) -> ActivityCorrectionOption {
        ActivityCorrectionOption(
            id: "watch.\(kind.rawValue)",
            title: kind.title,
            behavior: kind.rawValue,
            categoryID: kind.isMovement ? "movement" : (kind == .sleep ? "sleep" : "activity"),
            systemImage: kind.systemImage,
            isAutomatic: automatic,
            isCustom: false
        )
    }

    private static func option(
        for context: StationaryContextKind,
        automatic: Bool = false
    ) -> ActivityCorrectionOption {
        ActivityCorrectionOption(
            id: "context.\(context.rawValue)",
            title: context.title,
            behavior: context.rawValue,
            categoryID: context.categoryID,
            systemImage: context.systemImage,
            isAutomatic: automatic,
            isCustom: false
        )
    }

    static func activitySystemImage(
        title: String,
        behavior: String?,
        categoryID: String
    ) -> String {
        if let behavior,
           let kind = WatchBehaviorKind.fromModelLabel(behavior) {
            return kind.systemImage
        }
        if let behavior,
           let context = StationaryContextKind(rawValue: behavior) {
            return context.systemImage
        }

        let text = "\(title) \(behavior ?? "")"
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
        let matches: [(String, String)] = [
            ("지하철", "tram.fill"), ("subway", "tram.fill"),
            ("버스", "bus.fill"), ("bus", "bus.fill"),
            ("자동차", "car.fill"), ("자가용", "car.fill"),
            ("택시", "taxi.fill"), ("자전거", "bicycle"),
            ("걷", "figure.walk"), ("walk", "figure.walk"),
            ("달리", "figure.run"), ("run", "figure.run"),
            ("샤워", "shower.fill"), ("shower", "shower.fill"),
            ("양치", "toothbrush.fill"), ("brush", "toothbrush.fill"),
            ("집안일", "washer.fill"), ("청소", "washer.fill"),
            ("식사", "fork.knife"), ("meal", "fork.knife"),
            ("타이핑", "keyboard"), ("typing", "keyboard"),
            ("서기", "figure.stand"), ("standing", "figure.stand"),
            ("앉기", "figure.seated.side"), ("sitting", "figure.seated.side"),
            ("눕기", "bed.double.fill"), ("수면", "bed.double.fill"),
            ("lying", "bed.double.fill"), ("sleep", "bed.double.fill"),
            ("집에서휴식", "house.fill"), ("정지", "pause.circle.fill"),
            ("휴식", "sofa.fill"),
            ("rest", "sofa.fill"), ("통화", "phone.fill"),
            ("회의", "person.3.fill"), ("근무", "briefcase.fill"),
            ("수업", "book.fill"), ("학습", "book.fill"),
            ("운동시설", "dumbbell.fill"), ("gym", "dumbbell.fill"),
            ("운동", "figure.run"),
            ("카페", "cup.and.saucer.fill"), ("cafe", "cup.and.saucer.fill"),
            ("대기", "hourglass"),
        ]
        if let match = matches.first(where: { text.contains($0.0) }) {
            return match.1
        }
        return TimelineRowKind(categoryID: categoryID)?.systemImage
            ?? "sparkles"
    }
}

private enum ActivityCorrectionTarget {
    case record(UUID)
    case unconfirmed(ActualRecord)

    var isUnconfirmed: Bool {
        if case .unconfirmed = self { return true }
        return false
    }
}

private struct ActivityCorrectionHierarchyPicker: View {
    let record: ActualRecord
    let options: [ActivityCorrectionOption]
    let onSelect: (ActivityCorrectionOption) -> Void
    @State private var selectedPhase: DayPhase

    init(
        record: ActualRecord,
        options: [ActivityCorrectionOption],
        onSelect: @escaping (ActivityCorrectionOption) -> Void
    ) {
        self.record = record
        self.options = options
        self.onSelect = onSelect
        _selectedPhase = State(
            initialValue: Self.phase(for: record)
        )
    }

    private var phaseChoices: [DayPhase] {
        let available = Set(options.map(Self.phase(for:)))
        let current = Self.phase(for: record)
        return DayPhase.timelineRows.filter {
            available.contains($0) || $0 == current
        }
    }

    private var detailOptions: [ActivityCorrectionOption] {
        options.filter { Self.phase(for: $0) == selectedPhase }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 5) {
                Text("일과")
                    .font(.taption(size: 9, weight: .bold))
                    .foregroundStyle(Color.tpSecondary)
                ForEach(phaseChoices, id: \.rawValue) { phase in
                    phaseButton(phase)
                }
            }
            .frame(width: 94, alignment: .leading)

            Divider()

            VStack(alignment: .leading, spacing: 5) {
                Text("상세활동")
                    .font(.taption(size: 9, weight: .bold))
                    .foregroundStyle(Color.tpSecondary)
                if detailOptions.isEmpty {
                    Text("선택 가능한 활동 없음")
                        .font(.taption(size: 9))
                        .foregroundStyle(Color.tpSecondary)
                        .frame(
                            maxWidth: .infinity,
                            minHeight: 38,
                            alignment: .leading
                        )
                } else {
                    ForEach(detailOptions) { option in
                        optionButton(option)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }

    private func phaseButton(_ phase: DayPhase) -> some View {
        let isSelected = selectedPhase == phase
        let tint = Self.phaseColor(phase)
        return Button {
            guard selectedPhase != phase else { return }
            selectedPhase = phase
        } label: {
            HStack(spacing: 5) {
                Image(systemName: Self.phaseSystemImage(phase))
                    .font(.taption(size: 10, weight: .semibold))
                    .frame(width: 15)
                Text(phase.title)
                    .font(
                        .taption(
                            size: 9.5,
                            weight: isSelected ? .bold : .regular
                        )
                    )
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected ? tint : Color.tpInk)
            .padding(.horizontal, 7)
            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
            .background(
                isSelected
                    ? tint.opacity(0.14)
                    : Color(red: 0.95, green: 0.95, blue: 0.96),
                in: RoundedRectangle(cornerRadius: 9)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func optionButton(
        _ option: ActivityCorrectionOption
    ) -> some View {
        let tint = PlanCategory(categoryID: option.categoryID).darkColor
        return Button {
            onSelect(option)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: option.systemImage)
                    .font(.taption(size: 10, weight: .semibold))
                    .frame(width: 17)
                Text(option.title)
                    .font(.taption(size: 10, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Spacer(minLength: 0)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            .background(
                tint.opacity(0.1),
                in: RoundedRectangle(cornerRadius: 9)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .stroke(tint.opacity(0.22), lineWidth: 0.7)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.title)
    }

    private static func phase(for record: ActualRecord) -> DayPhase {
        if record.categoryID == ReviewCoverageEngine.unconfirmedCategoryID {
            return .activity
        }
        if let behavior = record.behavior,
           let kind = WatchBehaviorKind.fromModelLabel(behavior) {
            return phase(for: kind)
        }
        return DayPhase.phase(forActivityCategory: record.categoryID)
    }

    private static func phase(
        for option: ActivityCorrectionOption
    ) -> DayPhase {
        if option.categoryID == ReviewCoverageEngine.unconfirmedCategoryID {
            return .activity
        }
        if let behavior = option.behavior,
           let kind = WatchBehaviorKind.fromModelLabel(behavior) {
            return phase(for: kind)
        }
        return DayPhase.phase(forActivityCategory: option.categoryID)
    }

    private static func phase(for kind: WatchBehaviorKind) -> DayPhase {
        switch kind {
        case .sleep: .sleep
        case .automotive, .publicTransit, .subway, .walking, .running,
             .cycling, .stairsUp, .stairsDown, .elevator: .movement
        case .exercise: .exercise
        default: .activity
        }
    }

    private static func phaseSystemImage(_ phase: DayPhase) -> String {
        switch phase {
        case .sleep: "moon.zzz.fill"
        case .movement: "figure.walk.motion"
        case .exercise: "figure.strengthtraining.traditional"
        case .work: "briefcase.fill"
        case .study: "book.fill"
        case .hobby: "paintpalette.fill"
        case .appointment: "calendar"
        case .unconfirmed: "questionmark.circle"
        default: "sparkles"
        }
    }

    private static func phaseColor(_ phase: DayPhase) -> Color {
        RecordTimelinePalette.detailColor(
            .dayPhase,
            token: phase.rawValue
        )
    }
}

private struct ActivityCorrectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: AppModel
    let target: ActivityCorrectionTarget
    let displayedSpan: TimeSpan?
    let showsQuickMenu: Bool
    @State private var customTitle = ""
    @State private var selectedOption: ActivityCorrectionOption?
    @State private var addedCustomOptions: [ActivityCorrectionOption] = []
    @State private var startAt: Date
    @State private var endAt: Date
    @State private var isSaving = false

    init(
        model: AppModel,
        recordID: UUID,
        displayedSpan: TimeSpan? = nil,
        showsQuickMenu: Bool = false
    ) {
        self.model = model
        target = .record(recordID)
        self.displayedSpan = displayedSpan
        self.showsQuickMenu = showsQuickMenu
        let record = model.snapshot.actuals.first { $0.id == recordID }
        let start = displayedSpan?.start ?? record?.startedAt ?? .now
        _startAt = State(initialValue: start)
        _endAt = State(
            initialValue: displayedSpan?.end
                ?? record?.endedAt
                ?? start.addingTimeInterval(5 * 60)
        )
        _selectedOption = State(initialValue: nil)
    }

    init(
        model: AppModel,
        unconfirmedSpan: TimeSpan,
        showsQuickMenu: Bool = false
    ) {
        self.model = model
        displayedSpan = nil
        self.showsQuickMenu = showsQuickMenu
        target = .unconfirmed(
            ActualRecord(
                planID: nil,
                title: "미확인",
                categoryID: ReviewCoverageEngine.unconfirmedCategoryID,
                startedAt: unconfirmedSpan.start,
                endedAt: unconfirmedSpan.end,
                source: .manual,
                confidence: .low,
                behavior: "unconfirmed-gap"
            )
        )
        _startAt = State(initialValue: unconfirmedSpan.start)
        _endAt = State(initialValue: unconfirmedSpan.end)
        _selectedOption = State(initialValue: nil)
    }

    private var record: ActualRecord? {
        switch target {
        case .record(let id):
            model.snapshot.actuals.first { $0.id == id }
        case .unconfirmed(let placeholder):
            placeholder
        }
    }

    private var options: [ActivityCorrectionOption] {
        guard let record else { return [] }
        return ActivityCorrectionCatalog.options(
            for: record,
            actuals: model.snapshot.actuals,
            customLabels: model.snapshot.settings.customActivityLabels
        )
    }

    private var quickOptions: [ActivityCorrectionOption] {
        guard let record else { return [] }
        return RecentActivitySelectionStore.prioritize(
            ActivityCorrectionCatalog.quickOptions(
                for: record,
                actuals: model.snapshot.actuals,
                customLabels: model.snapshot.settings.customActivityLabels
            )
        )
    }

    private var automaticOptions: [ActivityCorrectionOption] {
        options.filter(\.isAutomatic)
    }

    private var suggestedOptions: [ActivityCorrectionOption] {
        options.filter { !$0.isAutomatic && !$0.isCustom }
    }

    private var customOptions: [ActivityCorrectionOption] {
        var result = options.filter(\.isCustom)
        for option in addedCustomOptions
        where !result.contains(where: { $0.id == option.id }) {
            result.append(option)
        }
        return result
    }

    var body: some View {
        NavigationStack {
            List {
                if showsQuickMenu, let record, !quickOptions.isEmpty {
                    Section("빠른 변경") {
                        ActivityCorrectionHierarchyPicker(
                            record: record,
                            options: quickOptions,
                            onSelect: selectQuickOption
                        )
                    }
                }
                Section("시간 조정") {
                    DatePicker(
                        "시작",
                        selection: $startAt,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    DatePicker(
                        "끝",
                        selection: $endAt,
                        in: startAt...,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    HStack {
                        Text("표시 시간")
                        Spacer()
                        Text(durationText)
                            .foregroundStyle(Color.tpProjectDark)
                            .font(.taption(size: 11, weight: .semibold))
                    }
                }
                if !automaticOptions.isEmpty {
                    Section("자동으로 구분된 활동") {
                        ForEach(automaticOptions) { optionRow($0) }
                    }
                }
                Section("활동 선택") {
                    ForEach(suggestedOptions) { optionRow($0) }
                }
                if !customOptions.isEmpty {
                    Section("내가 추가한 활동") {
                        ForEach(customOptions) { optionRow($0) }
                    }
                }
                Section("활동 추가") {
                    HStack(spacing: 8) {
                        TextField("새 활동 이름", text: $customTitle)
                            .textInputAutocapitalization(.never)
                            .submitLabel(.done)
                            .onSubmit { addCustomActivity() }
                        Button("추가") {
                            addCustomActivity()
                        }
                        .disabled(customTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(target.isUnconfirmed ? "활동 결정" : "활동 변경")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("저장") { save() }
                        .fontWeight(.semibold)
                        .disabled(
                            isSaving
                                || endAt <= startAt
                                || target.isUnconfirmed && selectedOption == nil
                        )
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("닫기") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func selectQuickOption(_ option: ActivityCorrectionOption) {
        guard !isSaving, endAt > startAt else { return }
        RecentActivitySelectionStore.remember(option)
        selectedOption = option
        // `@State` is committed on the next render pass. Passing the option
        // directly avoids saving the previous selection when the quick menu
        // closes immediately after a tap.
        save(option: option)
    }

    private func optionRow(_ option: ActivityCorrectionOption) -> some View {
        Button {
            select(option)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: option.systemImage)
                    .frame(width: 22)
                    .foregroundStyle(PlanCategory(categoryID: option.categoryID).darkColor)
                Text(option.title)
                    .foregroundStyle(Color.tpInk)
                Spacer()
                if isSelected(option) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.tpProjectDark)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func isSelected(_ option: ActivityCorrectionOption) -> Bool {
        guard let record else { return false }
        if let selectedOption {
            return selectedOption.id == option.id
        }
        let current = ActivityCorrection(
            title: record.title,
            behavior: record.behavior,
            categoryID: record.categoryID,
            startedAt: nil,
            endedAt: nil
        )
        guard option.correction == current else { return false }
        return options.first(where: { $0.correction == current })?.id == option.id
    }

    private func select(_ option: ActivityCorrectionOption) {
        selectedOption = option
    }

    private func addCustomActivity() {
        let title = customTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        customTitle = ""
        let option = ActivityCorrectionOption.custom(title)
        guard !customOptions.contains(where: {
            $0.title.localizedCaseInsensitiveCompare(title) == .orderedSame
        }) else {
            selectedOption = customOptions.first {
                $0.title.localizedCaseInsensitiveCompare(title) == .orderedSame
            }
            return
        }
        addedCustomOptions.append(option)
        selectedOption = option
    }

    private var durationText: String {
        DurationText.korean(max(0, endAt.timeIntervalSince(startAt)))
    }

    private func save(option selectedOverride: ActivityCorrectionOption? = nil) {
        guard !isSaving, endAt > startAt else { return }
        let option = selectedOverride ?? selectedOption
        if target.isUnconfirmed, option == nil { return }
        if let option {
            RecentActivitySelectionStore.remember(option)
        }
        isSaving = true
        Task {
            defer { isSaving = false }
            switch target {
            case .record(let recordID):
                if let displayedSpan {
                    await model.correctActualFragment(
                        recordID,
                        displayedSpan: displayedSpan,
                        startAt: startAt,
                        endAt: endAt,
                        with: option
                    )
                } else {
                    if let option {
                        await model.updateActualActivity(recordID, with: option)
                    }
                    await model.updateActualSpan(
                        recordID,
                        startAt: startAt,
                        endAt: endAt
                    )
                }
            case .unconfirmed:
                guard let option else { return }
                await model.classifyUnconfirmedSpan(
                    TimeSpan(start: startAt, end: endAt),
                    with: option
                )
            }
            dismiss()
        }
    }
}


#Preview {
    ReviewView(model: AppModel())
}
