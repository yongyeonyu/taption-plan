import SwiftUI

extension ReviewView {
    // MARK: - 원형 눈금판 그리기

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
        let outer = ReviewClockGeometry.outerRadius(side: side)
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
        ReviewClockOpacity.activity(
            categoryID: categoryID,
            highlight: highlight,
            isPlaybackActive: isPlaybackActive,
            isUnderPlayhead: isUnderPlayhead
        )
    }

    func activityDetailOpacity(
        kind: RecordClockDetailKind,
        token: String,
        highlight: ReviewClockHighlight?
    ) -> Double {
        ReviewClockOpacity.activityDetail(
            kind: kind,
            token: token,
            highlight: highlight
        )
    }

    func activityCategoryID(
        for kind: RecordClockDetailKind?
    ) -> String? {
        ReviewClockOpacity.activityCategoryID(for: kind)
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
        ReviewClockOpacity.phase(
            token: token,
            focusedToken: focusedToken,
            highlight: highlight,
            isPlaying: isPlaying
        )
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
        ReviewClockGeometry.angle(fraction)
    }

    func point(
        center: CGPoint,
        radius: CGFloat,
        angle: Angle
    ) -> CGPoint {
        ReviewClockGeometry.point(center: center, radius: radius, angle: angle)
    }
}
