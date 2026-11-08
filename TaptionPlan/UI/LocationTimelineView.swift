import MapKit
import SwiftUI

struct LocationTimelineView: View {
    @Bindable var model: AppModel
    @State private var viewportStart: CGFloat = 0
    @State private var viewportLength: CGFloat = 1
    @State private var dragStart: CGFloat?
    @State private var magnifyStart: (
        start: CGFloat,
        length: CGFloat
    )?
    @State private var lastDragRenderUptime: TimeInterval = 0
    @State private var lastMagnifyRenderUptime: TimeInterval = 0

    var body: some View {
        VStack(spacing: 0) {
            DraftTopBar(
                title: model.selectedDate.formatted(
                    Date.FormatStyle()
                        .month(.defaultDigits)
                        .day(.defaultDigits)
                        .weekday(.wide)
                        .locale(Locale(identifier: "ko_KR"))
                ),
                trailing: "\(Calendar.autoupdatingCurrent.component(.year, from: model.selectedDate))",
                selectedScale: .day,
                onScaleChange: {
                    model.selectScale($0)
                    model.detail = nil
                }
            )

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    Button {
                        model.detail = .inference
                    } label: {
                        HStack(spacing: TaptionSpacing.cozy) {
                            Image(systemName: "mappin.and.ellipse")
                                .foregroundStyle(Color(red: 0.18, green: 0.54, blue: 0.36))
                            Text(locationStatusTitle)
                                .fontWeight(.bold)
                            Spacer()
                            Text(
                                model.currentAltitudeStatus
                                    ?? sensorSignalLabel
                            )
                                .font(.taption(size: 9.5))
                                .foregroundStyle(Color.tpSecondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.72)
                        }
                        .font(.taption(size: 10.5))
                        .foregroundStyle(Color(red: 0.14, green: 0.37, blue: 0.49))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            Color(red: 0.93, green: 0.97, blue: 0.98),
                            in: RoundedRectangle(cornerRadius: TaptionRadius.panel)
                        )
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 10)
                    .padding(.top, 9)
                    .padding(.bottom, 7)

                    compactTimeAxis

                    ZStack(alignment: .topLeading) {
                        VStack(spacing: 0) {
                            placeRow
                            moveRow
                            projectRow
                        }
                        TimelineView(.periodic(from: .now, by: 60)) { context in
                            currentLocationLine(at: context.date)
                        }
                    }
                    .frame(height: 208)
                    .clipped()
                    .overlay {
                        GeometryReader { proxy in
                            Color.clear
                                .contentShape(Rectangle())
                                .gesture(
                                    viewportDragGesture(
                                        width: max(
                                            1,
                                            proxy.size.width - 50
                                        )
                                    )
                                )
                                .simultaneousGesture(
                                    viewportMagnifyGesture
                                )
                        }
                    }

                    routeDock
                        .padding(.horizontal, 8)
                        .padding(.top, 9)

                    HStack(spacing: TaptionSpacing.snug) {
                        Image(systemName: "lock")
                            .font(.taption(size: 15))
                            .foregroundStyle(Color.tpPlaceDark)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("센서 결과는 신뢰도와 함께 기기 안에서 정리")
                                .font(.taption(size: 9, weight: .bold))
                                .foregroundStyle(Color.tpInk)
                            Text("정확한 주소·원시 좌표는 기본 타임라인에 표시하지 않음")
                                .font(.taption(size: 8))
                        }
                    }
                    .foregroundStyle(Color.tpSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(9)
                    .background(Color.tpCard, in: RoundedRectangle(cornerRadius: TaptionRadius.compact))
                    .overlay {
                        RoundedRectangle(cornerRadius: TaptionRadius.compact)
                            .stroke(Color.tpControlStroke, lineWidth: 1)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
            }
            .background(Color.tpCard)
        }
        .task(id: model.selectedDate) {
            await model.refreshSensorTimeline()
        }
    }

    private var compactTimeAxis: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: 50)
            ForEach(viewportTickDates, id: \.self) { date in
                Text(viewportTickLabel(date))
                    .font(.taption(size: 10))
                    .foregroundStyle(Color.tpSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 4)
        .frame(height: 28)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.tpLine).frame(height: 0.5) }
    }

    private var placeRow: some View {
        HStack(spacing: 0) {
            rowLabel("위치", color: .tpPlaceDark)
            GeometryReader { proxy in
                ForEach(dayPlaces) { place in
                    let range = fractionRange(place.span)
                    locationBar(
                        placeLabel(place),
                        range.lowerBound,
                        range.upperBound - range.lowerBound,
                        proxy
                    )
                }
                ForEach(dayFloors) { floor in
                    floorMarker(floor, proxy: proxy)
                }
                if dayPlaces.isEmpty {
                    emptyRowText("머문 장소를 감지하면 여기에 표시됩니다")
                }
            }
        }
        .frame(height: 78)
        .background(Color(red: 0.98, green: 0.99, blue: 1.00))
        .overlay(alignment: .bottom) { Rectangle().fill(Color.tpLine.opacity(0.5)).frame(height: 0.5) }
    }

    private var moveRow: some View {
        HStack(spacing: 0) {
            rowLabel("이동", color: .tpTransitDark)
            GeometryReader { proxy in
                ForEach(dayTravel) { travel in
                    let range = fractionRange(travel.span)
                    moveBar(
                        travel.mode.outlineSymbolName,
                        range.lowerBound,
                        range.upperBound - range.lowerBound,
                        proxy,
                        dashed: travel.confidence == .low
                    )
                }
                if dayTravel.isEmpty {
                    emptyRowText("위치 사이 이동을 자동으로 분류합니다")
                }
            }
        }
        .frame(height: 70)
        .background(Color(red: 1.00, green: 0.99, blue: 0.97))
        .overlay(alignment: .bottom) { Rectangle().fill(Color.tpLine.opacity(0.5)).frame(height: 0.5) }
    }

    private var projectRow: some View {
        HStack(spacing: 0) {
            rowLabel("프로젝트", color: .tpProjectDark, compact: true)
            GeometryReader { proxy in
                ForEach(dayPlans) { plan in
                    let range = fractionRange(plan.span)
                    simpleBar(
                        plan.title,
                        start: range.lowerBound,
                        length: range.upperBound - range.lowerBound,
                        proxy: proxy
                    )
                }
                if dayPlans.isEmpty {
                    emptyRowText("같은 시간의 계획이 함께 표시됩니다")
                }
            }
        }
        .frame(height: 60)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.tpLine.opacity(0.5)).frame(height: 0.5) }
    }

    @ViewBuilder
    private func currentLocationLine(at date: Date) -> some View {
        if visibleTimelineSpan.contains(date) {
        GeometryReader { proxy in
            let x = 50 + max(1, proxy.size.width - 50)
                * fraction(for: date)
            Rectangle()
                .fill(Color.tpNow)
                .frame(width: 2, height: proxy.size.height)
                .position(x: x, y: proxy.size.height / 2)
            Text(date.formatted(date: .omitted, time: .shortened))
                .font(.taption(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.tpNow, in: Capsule())
                .position(x: x, y: 7)
        }
        }
    }

    private var routeDock: some View {
        VStack(spacing: 0) {
            HStack {
                Text("오늘 움직인 경로")
                    .font(.taption(size: 10.5, weight: .bold))
                Spacer()
                HStack(spacing: 3) {
                    Circle().fill(Color(red: 0.27, green: 0.83, blue: 0.51)).frame(width: 5, height: 5)
                    Text("위 시간축과 실시간 동기화")
                }
                .font(.taption(size: 7.5))
                .foregroundStyle(Color(red: 0.56, green: 0.94, blue: 0.72))
            }
            .padding(.bottom, 4)

            HStack {
                ForEach(viewportTickDates, id: \.self) { date in
                    Text(viewportTickLabel(date))
                        .frame(
                            maxWidth: .infinity,
                            alignment: .leading
                        )
                }
            }
            .font(.taption(size: 6))
            .foregroundStyle(Color(red: 0.41, green: 0.41, blue: 0.44))

            GeometryReader { proxy in
                Rectangle()
                    .fill(Color(red: 0.27, green: 0.27, blue: 0.29))
                    .frame(height: 1)
                    .position(x: proxy.size.width / 2, y: 28)

                ForEach(dayPlaces) { place in
                    let range = fractionRange(place.span)
                    routeSegment(
                        .tpPlaceDark,
                        range.lowerBound,
                        range.upperBound - range.lowerBound,
                        proxy
                    )
                    routeNode(
                        "\(placeLabel(place))\n\(place.span.end.formatted(date: .omitted, time: .shortened))",
                        range.upperBound,
                        above: dayPlaces.firstIndex(where: {
                            $0.id == place.id
                        })?.isMultiple(of: 2) ?? true,
                        proxy
                    )
                }
                ForEach(dayTravel) { travel in
                    let range = fractionRange(travel.span)
                    routeSegment(
                        travel.mode.routeColor,
                        range.lowerBound,
                        range.upperBound - range.lowerBound,
                        proxy,
                        dashed: travel.confidence == .low
                    )
                }
                ForEach(dayFloors) { floor in
                    let point = fraction(for: floor.span.end)
                    Text(floor.floorChangeLabel)
                        .font(.taption(size: 6, weight: .black))
                        .foregroundStyle(.white)
                        .position(x: proxy.size.width * point, y: 47)
                }

                if dayPlaces.isEmpty && dayTravel.isEmpty {
                    Text("오늘의 위치·이동 기록이 아직 없습니다")
                        .font(.taption(size: 8.5, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.72))
                        .position(
                            x: proxy.size.width / 2,
                            y: 28
                        )
                }

                TimelineView(.periodic(from: .now, by: 60)) { context in
                    if visibleTimelineSpan.contains(context.date) {
                        let current = fraction(for: context.date)
                        Rectangle()
                            .fill(Color.tpNow)
                            .frame(width: 2, height: 49)
                            .position(
                                x: proxy.size.width * current,
                                y: 31
                            )
                        Circle()
                            .fill(Color.tpNow)
                            .frame(width: 12, height: 12)
                            .position(
                                x: proxy.size.width * current,
                                y: 28
                            )
                        Text(
                            context.date.formatted(
                                date: .omitted,
                                time: .shortened
                            )
                        )
                        .font(.taption(size: 6, weight: .black))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(
                            Color.tpNow,
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                        .position(
                            x: min(
                                proxy.size.width - 23,
                                max(23, proxy.size.width * current)
                            ),
                            y: 7
                        )
                    }
                }
            }
            .frame(height: 62)
            .clipped()
            .overlay {
                GeometryReader { proxy in
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(
                            viewportDragGesture(
                                width: max(1, proxy.size.width)
                            )
                        )
                        .simultaneousGesture(viewportMagnifyGesture)
                }
            }

            HStack {
                Text("길이 = 실제 시간 · 빨간 선 = 현재")
                Spacer()
                Button {
                    followNow()
                } label: {
                    Text(
                        viewportLength < 0.999
                            ? "지금으로"
                            : "밀기·핀치로 함께 탐색"
                    )
                }
                .buttonStyle(.plain)
                .foregroundStyle(
                    Color(red: 0.78, green: 0.78, blue: 0.80)
                )
            }
            .font(.taption(size: 6.8))
            .foregroundStyle(Color(red: 0.56, green: 0.56, blue: 0.58))
            .padding(.top, 6)
            .overlay(alignment: .top) {
                Rectangle().fill(Color(red: 0.19, green: 0.19, blue: 0.21)).frame(height: 0.5)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 9)
        .padding(.vertical, 10)
        .background(Color(red: 0.09, green: 0.09, blue: 0.10), in: RoundedRectangle(cornerRadius: 15))
        .shadow(color: .black.opacity(0.16), radius: 9, y: 6)
    }

    private func rowLabel(_ title: String, color: Color, compact: Bool = false) -> some View {
        HStack(spacing: TaptionSpacing.tight) {
            RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 8, height: 8)
            Text(title)
                .font(.taption(size: compact ? 9 : 10.5, weight: .semibold))
                .minimumScaleFactor(0.7)
                .lineLimit(1)
        }
        .padding(.leading, compact ? 4 : 8)
        .frame(width: 50, alignment: .leading)
    }

    private func locationBar(_ title: String, _ start: CGFloat, _ length: CGFloat, _ proxy: GeometryProxy) -> some View {
        Text(title)
            .font(.taption(size: 9.5, weight: .black))
            .foregroundStyle(Color(red: 0.14, green: 0.37, blue: 0.49))
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(width: max(17, proxy.size.width * length), height: 32)
            .background(Color.tpPlace, in: RoundedRectangle(cornerRadius: TaptionRadius.control))
            .overlay { RoundedRectangle(cornerRadius: TaptionRadius.control).stroke(Color.tpPlaceDark.opacity(0.35)) }
            .position(x: proxy.size.width * start + max(17, proxy.size.width * length) / 2, y: 31)
    }

    private func moveBar(_ icon: String, _ start: CGFloat, _ length: CGFloat, _ proxy: GeometryProxy, dashed: Bool = false) -> some View {
        Image(systemName: icon)
            .font(.taption(size: 11))
            .foregroundStyle(Color(red: 0.44, green: 0.29, blue: 0.09))
            .frame(width: max(14, proxy.size.width * length), height: 29)
            .background(Color.tpTransit.opacity(dashed ? 0.68 : 1), in: RoundedRectangle(cornerRadius: TaptionRadius.control))
            .overlay {
                RoundedRectangle(cornerRadius: TaptionRadius.control)
                    .stroke(Color.tpTransitDark.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: dashed ? [3, 2] : []))
            }
            .position(x: proxy.size.width * start + max(14, proxy.size.width * length) / 2, y: 32)
    }

    private func simpleBar(_ title: String, start: CGFloat, length: CGFloat, proxy: GeometryProxy) -> some View {
        Text(title)
            .font(.taption(size: 10.5, weight: .semibold))
            .foregroundStyle(Color.tpInk.opacity(0.64))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .frame(width: max(18, proxy.size.width * length), height: 26, alignment: .leading)
            .background(Color.tpProject, in: RoundedRectangle(cornerRadius: TaptionRadius.tight))
            .position(x: proxy.size.width * start + max(18, proxy.size.width * length) / 2, y: 29)
    }

    private func routeSegment(
        _ color: Color,
        _ start: CGFloat,
        _ length: CGFloat,
        _ proxy: GeometryProxy,
        dashed: Bool = false
    ) -> some View {
        Capsule()
            .fill(color.opacity(dashed ? 0.48 : 1))
            .frame(width: max(2, proxy.size.width * length), height: 7)
            .overlay {
                if dashed {
                    Capsule().stroke(
                        .white.opacity(0.65),
                        style: StrokeStyle(lineWidth: 1, dash: [3, 2])
                    )
                }
            }
            .position(x: proxy.size.width * start + max(2, proxy.size.width * length) / 2, y: 28)
    }

    private func routeNode(_ title: String, _ position: CGFloat, above: Bool, _ proxy: GeometryProxy) -> some View {
        ZStack {
            Circle()
                .fill(Color(red: 0.09, green: 0.09, blue: 0.10))
                .overlay { Circle().stroke(.white, lineWidth: 2) }
                .frame(width: 11, height: 11)
            Text(title)
                .font(.taption(size: 6))
                .multilineTextAlignment(.center)
                .fixedSize()
                .offset(y: above ? -19 : 19)
        }
        .position(x: proxy.size.width * position, y: 28)
    }

    private var daySpan: TimeSpan {
        TimelineAggregationEngine().interval(
            for: .day,
            containing: model.selectedDate
        )
    }

    private var dayPlaces: [PlaceStay] {
        model.snapshot.places.overlapping(visibleTimelineSpan, by: \.span)
    }

    private var dayTravel: [TravelSegment] {
        model.snapshot.travel.overlapping(visibleTimelineSpan, by: \.span)
    }

    private var dayFloors: [FloorTransition] {
        model.snapshot.floorTransitions.overlapping(visibleTimelineSpan, by: \.span)
    }

    private var dayPlans: [PlanRecord] {
        model.snapshot.plans.overlapping(visibleTimelineSpan, by: \.span)
    }

    private var locationStatusTitle: String {
        if model.isSensorCollecting { return "위치·이동 기록 중" }
        if model.settings.locationEnabled { return "위치·이동 대기 중" }
        return "위치·이동 연결 필요"
    }

    private var sensorSignalLabel: String {
        guard let availability = model.sensorAvailability else {
            return "GPS · 모션 · 기압 · HealthKit"
        }
        var values: [String] = []
        if availability.location { values.append("GPS") }
        if availability.motionActivity { values.append("모션") }
        if availability.relativeAltitude { values.append("기압") }
        if model.settings.healthEnabled { values.append("HealthKit") }
        return values.isEmpty ? "센서 확인 필요" : values.joined(separator: " · ")
    }

    private func placeLabel(_ place: PlaceStay) -> String {
        var values = [place.displayName]
        if let floor = place.floor {
            values.append("\(floor)F")
        }
        if let point = place.point {
            values.append("해발 \(Int(point.altitude.rounded()))m")
        }
        return values.joined(separator: "·")
    }

    private func fraction(for date: Date) -> CGFloat {
        visibleTimelineSpan.clampedFraction(of: date)
    }

    private func fractionRange(_ span: TimeSpan) -> ClosedRange<CGFloat> {
        let overlap = span.intersection(with: visibleTimelineSpan)
            ?? span
        return fraction(for: overlap.start)...fraction(for: overlap.end)
    }

    private var visibleTimelineSpan: TimeSpan {
        TimeSpan(
            start: daySpan.start.addingTimeInterval(
                daySpan.duration * TimeInterval(viewportStart)
            ),
            end: daySpan.start.addingTimeInterval(
                daySpan.duration
                    * TimeInterval(viewportStart + viewportLength)
            )
        )
    }

    private var viewportTickDates: [Date] {
        (0..<6).map { index in
            visibleTimelineSpan.start.addingTimeInterval(
                visibleTimelineSpan.duration
                    * TimeInterval(index) / 6
            )
        }
    }

    private func viewportTickLabel(_ date: Date) -> String {
        let components = Calendar.autoupdatingCurrent.dateComponents(
            [.hour, .minute],
            from: date
        )
        let hour = components.hour ?? 0
        let minute = components.minute ?? 0
        if viewportLength >= 0.5 || minute == 0 {
            return String(format: "%02d", hour)
        }
        return String(format: "%02d:%02d", hour, minute)
    }

    private func viewportDragGesture(
        width: CGFloat
    ) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                if dragStart == nil {
                    dragStart = viewportStart
                }
                applyViewportDrag(
                    translation: value.translation.width,
                    width: width,
                    force: false
                )
            }
            .onEnded { value in
                applyViewportDrag(
                    translation: value.translation.width,
                    width: width,
                    force: true
                )
                dragStart = nil
                lastDragRenderUptime = 0
            }
    }

    private var viewportMagnifyGesture: some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.01)
            .onChanged { value in
                if magnifyStart == nil {
                    magnifyStart = (viewportStart, viewportLength)
                }
                applyViewportMagnification(
                    magnification: value.magnification,
                    force: false
                )
            }
            .onEnded { value in
                applyViewportMagnification(
                    magnification: value.magnification,
                    force: true
                )
                magnifyStart = nil
                lastMagnifyRenderUptime = 0
            }
    }

    private func applyViewportDrag(
        translation: CGFloat,
        width: CGFloat,
        force: Bool
    ) {
        guard let origin = dragStart else { return }
        if !force {
            guard TimelineInteractionFrameGate.shouldRender(
                lastUptime: &lastDragRenderUptime,
                nowUptime: ProcessInfo.processInfo.systemUptime
            ) else { return }
        }
        let next = clampedViewportStart(
            origin
                - translation / max(1, width) * viewportLength,
            length: viewportLength
        )
        if viewportStart != next {
            viewportStart = next
        }
    }

    private func applyViewportMagnification(
        magnification: CGFloat,
        force: Bool
    ) {
        guard let origin = magnifyStart else { return }
        if !force {
            guard TimelineInteractionFrameGate.shouldRender(
                lastUptime: &lastMagnifyRenderUptime,
                nowUptime: ProcessInfo.processInfo.systemUptime
            ) else { return }
        }
        let newLength = max(
            0.125,
            min(1, origin.length / magnification)
        )
        let center = origin.start + origin.length / 2
        let nextStart = clampedViewportStart(
            center - newLength / 2,
            length: newLength
        )
        if viewportLength != newLength {
            viewportLength = newLength
        }
        if viewportStart != nextStart {
            viewportStart = nextStart
        }
    }

    private func clampedViewportStart(
        _ value: CGFloat,
        length: CGFloat
    ) -> CGFloat {
        max(0, min(1 - length, value))
    }

    private func followNow() {
        guard daySpan.contains(.now) else {
            viewportStart = 0
            viewportLength = 1
            return
        }
        if viewportLength >= 0.999 {
            viewportStart = 0
            return
        }
        let nowFraction = CGFloat(
            Date.now.timeIntervalSince(daySpan.start)
                / max(1, daySpan.duration)
        )
        withAnimation(.easeOut(duration: 0.22)) {
            viewportStart = clampedViewportStart(
                nowFraction - viewportLength * 0.65,
                length: viewportLength
            )
        }
    }

    private func floorMarker(
        _ floor: FloorTransition,
        proxy: GeometryProxy
    ) -> some View {
        let x = proxy.size.width * fraction(for: floor.span.end)
        return ZStack {
            Rectangle()
                .fill(Color.tpPlaceDark)
                .frame(width: 2, height: 64)
            Text(floor.floorChangeLabel)
                .font(.taption(size: 6.5, weight: .black))
                .foregroundStyle(Color.tpPlaceDark)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(Color.tpCard, in: RoundedRectangle(cornerRadius: TaptionRadius.tight))
                .overlay {
                    RoundedRectangle(cornerRadius: TaptionRadius.tight)
                        .stroke(Color.tpPlaceDark.opacity(0.35))
                }
                .offset(y: -25)
        }
        .position(x: x, y: 39)
    }

    private func emptyRowText(_ text: String) -> some View {
        Text(text)
            .font(.taption(size: 8.5))
            .foregroundStyle(Color.tpSecondary.opacity(0.72))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private extension FloorTransition {
    var floorChangeLabel: String {
        if let fromFloor, let toFloor {
            let delta = toFloor - fromFloor
            return "\(delta >= 0 ? "↑" : "↓")\(abs(delta))F"
        }
        return String(
            format: "%@%.1fm",
            relativeAltitudeMeters >= 0 ? "↑" : "↓",
            abs(relativeAltitudeMeters)
        )
    }
}
