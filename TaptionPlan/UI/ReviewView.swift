import Charts
import SwiftUI

struct ReviewView: View {
    @Bindable var model: AppModel

    /// 24시간 눈금 안쪽에 기록을 담는 띠. 하나만 두고 굵게 그린다.
    static let clockBandWidth: CGFloat = 20
    /// 활동 띠 바깥에 두르는 일과 띠.
    static let phaseBandWidth: CGFloat = 12
    /// 일과와 활동 두 띠가 서로 붙어 보이지 않을 만큼만 벌린다.
    static let bandGap: CGFloat = 3.5
    static let clockButtonSize: CGFloat = 44
    static let cornerLabelWidth: CGFloat = 108
    static let cornerLabelHeight: CGFloat = 46
    /// 일과 띠를 두르면서 안쪽 띠가 가운데 단추와 읽음창에 밀리지 않도록
    /// 눈금판을 키웠다. 카드 너비(약 343pt)보다 작아 가로로 넘치지 않는다.
    ///
    /// 읽음창이 이름 옆에 "오전 11:12–오후 12:45"까지 적으면서 가운데 빈
    /// 자리가 더 필요해졌다. 띠를 모두 두르고 한 칸 띄우면 남는 반지름은
    /// `한 변/2 - 86`이고, 재생 단추 아래 알약은 가장 긴 문구일 때 가장 먼
    /// 모서리가 중심에서 약 75pt 떨어진다. 324pt면 76pt가 남는다. 더 좁은
    /// 화면에서는 한 변이 카드 너비에 묶이므로, 알약이 남은 자리에 맞춰
    /// 스스로 줄어든다.
    static let clockHeight: CGFloat = 324
    static let circularClockLegendMargin: CGFloat = 20
    static let linearClockHeight: CGFloat = 174
    static let linearTimelineHeight: CGFloat = 122
    static let linearTimelineInset: CGFloat = 82
    static let clockLinearThreshold: CGFloat = 1.08

    @State var content = ReviewContent.empty
    @State var collapsedGroupIDs: Set<String> = []
    /// 켜 둔 칸. 비어 있으면 기간 전체를 본다.
    @State var selectedBucketIDs: Set<String> = []
    /// 주·월·년 막대에서 직접 고른 하루 또는 한 달.
    @State var selectedChartBucketID: String?
    /// 범례에서 고른 한 항목. 서로 배타적으로 유지해 다른 띠는 흐리게 남긴다.
    @State var clockHighlight: ReviewClockHighlight?
    @State var circularActivityLabelPageIndices:
        [CircularActivityLabelQuadrant: Int] = [:]
    /// 재생을 시작한 시각. nil이면 멈춘 상태다.
    @State var playStartedAt: Date?
    /// 하루 원형 시간표의 핀치 배율. 1배율은 원형, 그보다 크면 직선
    /// 시간표로 바꿔 두 줄(일과·활동)로 보여 준다.
    @State var clockZoomScale: CGFloat = 1
    @State var clockMagnifyOrigin: CGFloat?
    @State var lastClockZoomRenderUptime: TimeInterval = 0
    @State var linearScrollPosition = ScrollPosition(x: 0)
    @State var linearPlayheadFraction = 0.5
    @State var circularPlayheadFraction: Double?
    @State var linearPositionedPeriodStart: Date?
    @State var unconfirmedSelection: ReviewUnconfirmedSelection?
    @State var quickActivitySelection: ReviewQuickActivitySelection?
    @State var linearScrollTracker = LinearScrollTracker()
    @State var circularPlayheadTracker = CircularPlayheadTracker()

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
    func stopPlaybackWhenSweepEnds() async {
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

    var highlightedCategoryID: String? {
        guard case .category(let id) = clockHighlight else { return nil }
        return id
    }

    var highlightedDetail: ReviewDetailSelection? {
        guard case .detail(let selection) = clockHighlight else { return nil }
        return selection
    }

    var highlightedPhaseToken: String? {
        guard case .phase(_, let token) = clockHighlight else { return nil }
        return token
    }

    func clearClockHighlight() {
        guard clockHighlight != nil else { return }
        clockHighlight = nil
    }

    // MARK: - 머리말

    var reviewHeader: some View {
        VStack(spacing: TaptionSpacing.cozy) {
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
                                    RoundedRectangle(cornerRadius: TaptionRadius.tight)
                                        .fill(Color.tpSurface)
                                        .shadow(
                                            color: Color.tpSky.opacity(0.24),
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
                Color.tpSky.opacity(0.18),
                in: RoundedRectangle(cornerRadius: TaptionRadius.control)
            )

            if !content.pickableBuckets.isEmpty {
                bucketPicker
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 5)
        .padding(.bottom, 8)
        .background(
            LinearGradient(
                colors: [Color.tpSurface, Color.tpSurfaceBlue.opacity(0.48)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.tpLine).frame(height: 0.5)
        }
    }

    /// 칸을 눌러 켜고 끈다. 여러 칸을 켜면 합쳐서 보고, 모두 끄면 기간
    /// 전체로 돌아간다. 따로 "고르기 모드"로 들어가지 않는다.
    var bucketPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: TaptionSpacing.compact) {
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

    func bucketChipLabel(
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
                : Color.tpSky.opacity(0.12),
            in: Capsule()
        )
        .overlay {
            Capsule().stroke(
                isSelected ? Color.tpProjectDark.opacity(0.55) : .clear,
                lineWidth: 1
            )
        }
    }

    func toggle(_ bucket: ReviewPeriodBucket) {
        clearClockHighlight()
        selectedChartBucketID = nil
        if selectedBucketIDs.contains(bucket.id) {
            selectedBucketIDs.remove(bucket.id)
        } else {
            selectedBucketIDs.insert(bucket.id)
        }
    }
}

#Preview {
    ReviewView(model: AppModel())
}
