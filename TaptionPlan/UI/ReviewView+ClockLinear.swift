import SwiftUI

extension ReviewView {
    // MARK: - 확대한 직선 시간표

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
            let labelStride = ReviewClockGeometry.hourLabelStride(width: width)
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
            let bar = ReviewClockGeometry.linearBar(
                in: rect,
                startFraction: arc.startFraction,
                endFraction: arc.endFraction
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
            let bar = ReviewClockGeometry.linearBar(
                in: rect,
                startFraction: arc.startFraction,
                endFraction: arc.endFraction
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
        let fraction = ReviewClockGeometry.linearFraction(
            x: x,
            timelineStart: timelineStart,
            timelineWidth: timelineWidth
        )
        if let selection = recordForRing(at: fraction, categoryID: nil) {
            openRecord(selection)
        } else {
            openUnconfirmedEditor(at: fraction, categoryID: nil)
        }
    }
}
