import SwiftUI

extension ReviewView {
    // MARK: - 원형 눈금판 모서리 활동 라벨

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
        let lineRadius = ReviewClockGeometry.outerRadius(side: side) + 2

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
        ReviewClockGeometry.cornerLabelAnchor(
            quadrant: quadrant,
            in: size,
            labelWidth: Self.cornerLabelWidth,
            labelHeight: Self.cornerLabelHeight
        )
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
}
