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
}
