import Charts
import SwiftUI

extension ReviewView {
    // MARK: - 그림

    var chartCard: some View {
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
        .tpCardSurface(radius: 13, tint: .tpSurfaceBlue)
    }

    var emptyRecordText: some View {
        Text("이 기간에 저장된 실제 데이터가 없습니다.")
            .font(.taption(size: 10.5))
            .foregroundStyle(Color.tpSecondary)
    }

    var timelineLocationHeader: some View {
        HStack(spacing: TaptionSpacing.compact) {
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

    var timelineLocationText: String {
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

    var chartTitle: String {
        switch model.reviewScale {
        case .day: "하루 24시간"
        case .week: "요일별 기록"
        case .month: "날짜별 기록"
        case .year: "월별 기록"
        }
    }

    var chartSymbol: String {
        model.reviewScale == .day ? "clock" : "chart.bar.xaxis"
    }

    var recordedDuration: TimeInterval {
        if model.reviewScale == .day {
            return content.period.duration
        }
        return content.phaseDurations.reduce(0) { $0 + $1.actual }
    }

    /// 24시간 눈금판. 자정이 12시 방향이고 시계 방향으로 하루가 흐른다.
    /// 평소에는 눈금과 현재 시각 바늘만 두고, 기록은 재생하거나 범례에서
    /// 카테고리를 고를 때만 안쪽 띠에 굵게 드러낸다.
    var dayClockChart: some View {
        Group {
            if clockZoomScale >= Self.clockLinearThreshold {
                linearDayClockChart
            } else {
                circularDayClockChart
            }
        }
        .animation(.easeOut(duration: 0.16), value: clockZoomScale >= Self.clockLinearThreshold)
    }

    var circularDayClockChart: some View {
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

    var circularPlayheadOverlay: some View {
        TimelineView(
            RecordClockSchedule(isPlaying: playStartedAt != nil)
        ) { timeline in
            let fraction = clockPlaybackProgress(at: timeline.date)
                ?? idleCircularPlayheadFraction(at: timeline.date)
            circularPlayheadHandle(at: fraction)
        }
    }

    func circularPlayheadHandle(at fraction: Double) -> some View {
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

    func clockPlaybackProgress(at date: Date) -> Double? {
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

    func idleCircularPlayheadFraction(at date: Date) -> Double {
        circularPlayheadFraction
            ?? RecordClockEngine.nowFraction(in: content.period, asOf: date)
            ?? 0
    }

    var circularActivityLabels: some View {
        let labels = Dictionary(
            grouping: circularActivityLabelItems,
            by: \.quadrant
        )
        return VStack(spacing: 0) {
            HStack(alignment: .top, spacing: TaptionSpacing.tight) {
                circularActivityLabel(in: .topLeft, from: labels)
                Spacer(minLength: 4)
                circularActivityLabel(in: .topRight, from: labels)
            }
            Spacer(minLength: 0)
            HStack(alignment: .bottom, spacing: TaptionSpacing.tight) {
                circularActivityLabel(in: .bottomLeft, from: labels)
                Spacer(minLength: 4)
                circularActivityLabel(in: .bottomRight, from: labels)
            }
        }
        .padding(.horizontal, 3)
        .padding(.vertical, 4)
    }

    var circularActivityLeaderLines: some View {
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

    func drawCircularActivityLeaderLines(
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

    func circularActivityLabelAnchor(
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
    func circularActivityLabel(
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

    var circularActivityLabelItems: [CircularActivityLabel] {
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

    func detailSpans(
        for selection: ReviewDetailSelection
    ) -> [TimeSpan] {
        guard let ring = content.activityRings.first(where: {
            $0.kind == selection.kind
        }) else { return [] }
        return ring.arcs
            .filter { $0.token == selection.token }
            .map { RecordClockEngine.span(of: $0, in: content.period) }
    }

    func visibleCircularActivityLabels(
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

    func circularActivityLabel(
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
                    in: RoundedRectangle(cornerRadius: TaptionRadius.tight, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: TaptionRadius.tight, style: .continuous)
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

    func circularActivityPageButton(
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

    func moveCircularActivityLabel(
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

    var linearDayClockChart: some View {
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
                VStack(spacing: TaptionSpacing.regular) {
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

    var linearPlayheadLabels: some View {
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

    func linearPlayheadLabel(
        _ title: String,
        item: LinearClockItem
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.taption(size: 7.5, weight: .bold))
                .foregroundStyle(Color.tpSecondary)
            HStack(spacing: TaptionSpacing.tight) {
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

    var linearPhaseItem: LinearClockItem {
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

    var linearActivityItem: LinearClockItem {
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

    var linearPlayheadTimeText: String {
        content.period.start
            .addingTimeInterval(
                content.period.duration * linearPlayheadFraction
            )
            .formatted(date: .omitted, time: .shortened)
    }

    var linearLookupFraction: Double {
        min(linearPlayheadFraction, 1 - 0.000_001)
    }

    var linearPlayhead: some View {
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

    func updateCircularPlayhead(
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

    func finishCircularPlayheadDrag(
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

    func setManualPlayhead(_ fraction: Double) {
        let next = min(1, max(0, fraction))
        if circularPlayheadFraction.map({ abs($0 - next) > 0.00001 })
            != false {
            circularPlayheadFraction = next
        }
        if abs(linearPlayheadFraction - next) > 0.00001 {
            linearPlayheadFraction = next
        }
    }

    func clearManualPlayhead() {
        guard circularPlayheadFraction != nil else { return }
        circularPlayheadFraction = nil
        circularPlayheadTracker.lastPublishedUptime = 0
    }

    func adjustCircularPlayhead(
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

    func circularPlayheadTimeText(_ fraction: Double) -> String {
        content.period.start
            .addingTimeInterval(content.period.duration * fraction)
            .formatted(date: .omitted, time: .shortened)
    }

    func updateLinearPlayhead(
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

    func positionLinearTimeline(
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

    func moveLinearTimeline(
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

    func drawLinearClock(
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

    func drawLinearGrid(
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

    func drawLinearPlaceholder(
        context: GraphicsContext,
        rect: CGRect,
        color: Color
    ) {
        context.fill(
            Path(roundedRect: rect, cornerRadius: TaptionRadius.tight),
            with: .color(color)
        )
    }

    func drawLinearCategoryArcs(
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
                Path(roundedRect: bar, cornerRadius: TaptionRadius.tight),
                with: .color(color.opacity(opacity))
            )
        }
    }

    func drawLinearDetailArcs(
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

    func openLinearRecordEditor(
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

    func updateClockZoom(factor: CGFloat) {
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

    var clockMagnifyGesture: some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.001)
            .onChanged { value in
                updateClockZoom(factor: CGFloat(value.magnification))
            }
            .onEnded { value in
                finishClockZoom(factor: CGFloat(value.magnification))
            }
    }

    func finishClockZoom(factor: CGFloat) {
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

    func resetClockZoom() {
        clockMagnifyOrigin = nil
        lastClockZoomRenderUptime = 0
        if clockZoomScale != 1 { clockZoomScale = 1 }
    }

    /// 짚어 둔 조각. 범례에서 고른 경우에는 그 이름의 첫 조각을 짚는다.
    var highlightedPhaseArc: RecordClockDetailArc? {
        guard case .phase(let id, _) = clockHighlight else { return nil }
        return content.phaseRing?.arcs.first { $0.id == id }
    }

    func playbackContext(
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

    func currentContextReadout() -> PlaybackContextReadout? {
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

    func playbackContextView(
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
        .background(Color.tpSurfaceCream.opacity(0.96), in: RoundedRectangle(cornerRadius: TaptionRadius.small))
        .overlay {
            RoundedRectangle(cornerRadius: TaptionRadius.small)
                .stroke(Color.tpLine.opacity(0.7), lineWidth: 0.8)
        }
    }

    func playbackWeatherText(_ token: String) -> Text {
        guard let parts = WeatherClockToken.compactParts(token) else {
            return Text(token)
                .font(.taption(size: 7, weight: .medium))
                .foregroundStyle(Color.tpInk)
        }
        return Text(parts.weather)
            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(8))))
            .foregroundStyle(Color.tpInk)
            + Text(" \(parts.temperature)°")
                .font(.taption(size: 7, weight: .semibold))
                .foregroundStyle(Color.tpInk)
            + Text(" \(parts.air)")
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(5))))
                .foregroundStyle(Color.tpInk)
    }

    /// 원형 띠를 짚으면 빠른 활동 변경 메뉴를 연다. 재생 단추가 이 층 위에
    /// 덮여 있어 누르기를 가로채지 않는다.
    var clockTapLayer: some View {
        GeometryReader { proxy in
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { location in
                    openRecordEditor(at: location, in: proxy.size)
                }
        }
        .accessibilityHidden(true)
    }

    func openRecordEditor(at location: CGPoint, in size: CGSize) {
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

    func openRecord(_ selection: ReviewRecordSelection) {
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
    func openUnconfirmedEditor(
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

    func recordForRing(
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

    var playControl: some View {
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
                .background(Color.tpSurface, in: Circle())
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

    func toggleClockPlayback() {
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
    var dateSwipeGesture: some Gesture {
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

    func drawClock(
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
    func drawActivityDetailsOnBand(
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

    func activityOpacity(
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

    func activityDetailOpacity(
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

    func activityCategoryID(
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
    func drawPhaseRing(
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

    func phaseOpacity(
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
    func drawPhaseReadout(
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

    func detailColor(
        _ kind: RecordClockDetailKind,
        token: String
    ) -> Color {
        RecordTimelinePalette.detailColor(kind, token: token)
    }

    func detailName(
        _ kind: RecordClockDetailKind,
        token: String
    ) -> String {
        switch kind {
        case .dayPhase:
            return DayPhase(rawValue: token)?.title ?? token
        case .sleepStage:
            return SleepStage(rawValue: token)?.displayName ?? token
        case .travel:
            return RecordAnalysisCategoryPolicy.movementTitle(for: token)
        case .weather:
            return WeatherClockToken.displayName(token)
        case .location:
            return token
        }
    }

    /// 일과 띠의 색이 무엇을 뜻하는지 적는다. 카테고리 범례처럼 눌러서 하나만
    /// 살릴 수 있고, 그때 눈금판 가운데에도 같은 이름이 뜬다.
    func phaseLegend(_ ring: RecordClockDetailRing) -> some View {
        ChipFlowLayout(spacing: TaptionSpacing.compact) {
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
                    HStack(spacing: TaptionSpacing.tight) {
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
                            : Color.tpSky.opacity(0.12),
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

    func detailTokens(of ring: RecordClockDetailRing) -> [String] {
        var seen = Set<String>()
        return ring.arcs.map(\.token).filter { seen.insert($0).inserted }
    }

    func arcPath(
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

    func drawHand(
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

    func drawClockFace(
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

    func clockAngle(_ fraction: Double) -> Angle {
        .degrees(fraction * 360 - 90)
    }

    func point(
        center: CGPoint,
        radius: CGFloat,
        angle: Angle
    ) -> CGPoint {
        CGPoint(
            x: center.x + radius * cos(angle.radians),
            y: center.y + radius * sin(angle.radians)
        )
    }
}
