import SwiftUI

extension ReviewView {
    // MARK: - 원형 눈금판

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
        let outer = ReviewClockGeometry.outerRadius(side: side)
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
        let fraction = ReviewClockGeometry.clockFraction(dx: dx, dy: dy)

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
}
