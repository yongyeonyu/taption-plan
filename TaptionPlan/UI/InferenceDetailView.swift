import MapKit
import SwiftUI

struct InferenceDetailView: View {
    @Bindable var model: AppModel
    @State private var selectedGroupID: UUID?
    @State private var floorOverrides: [UUID: Int] = [:]
    @State private var routeReadings: [SensorReading] = []
    @State private var mapPosition: MapCameraPosition = .automatic
    @State private var routeMapViewportSize = CGSize.zero

    private let modes: [TravelMode] = [
        .walking, .running, .cycling, .bus, .subway,
        .taxi, .car, .train, .airplane, .ship,
    ]

    var body: some View {
        VStack(spacing: 0) {
            DetailHeader(title: "자동 추정 상세", trailing: "완료") {
                model.detail = .locationTimeline
            }

            ScrollView(showsIndicators: false) {
                VStack(spacing: TaptionSpacing.regular) {
                    Text("이동은 아래 10종류만 사용합니다. 센서가 직접 구분하지 못하는 수단은 여러 신호를 합쳐 신뢰도와 함께 표시합니다.")
                        .font(.taption(size: 9.5))
                        .foregroundStyle(Color.tpSecondary)
                        .lineSpacing(3)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    routeMapCard

                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: TaptionSpacing.compact) {
                        ForEach(modes, id: \.self) { mode in
                            Button {
                                guard let selectedGroup else { return }
                                model.confirmTravel(
                                    selectedGroup.segmentIDs,
                                    mode: mode
                                )
                            } label: {
                                VStack(spacing: TaptionSpacing.tight) {
                                    Image(systemName: mode.outlineSymbolName)
                                        .font(.taption(size: 15))
                                    Text(mode.displayName)
                                        .font(.taption(size: 7.5, weight: .bold))
                                }
                                .foregroundStyle(
                                    selectedGroup?.mode == mode
                                        ? Color.white
                                        : Color(red: 0.40, green: 0.27, blue: 0.11)
                                )
                                .frame(maxWidth: .infinity, minHeight: 48)
                                .background(
                                    selectedGroup?.mode == mode
                                        ? Color.tpTransitDark
                                        : Color.white,
                                    in: RoundedRectangle(cornerRadius: TaptionRadius.field)
                                )
                                .overlay {
                                    RoundedRectangle(cornerRadius: TaptionRadius.field)
                                        .stroke(
                                            selectedGroup?.mode == mode
                                                ? Color.tpTransitDark
                                                : Color(
                                                    red: 0.89,
                                                    green: 0.89,
                                                    blue: 0.91
                                                ),
                                            lineWidth: 1
                                        )
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(selectedGroupID == nil)
                        }
                    }

                    if dayTravel.isEmpty && dayFloors.isEmpty {
                        ContentUnavailableView(
                            "확인할 추정 기록이 없습니다",
                            systemImage: "location.slash",
                            description: Text(
                                "위치·동작 센서가 이동이나 층 변화를 감지하면 여기에 나타납니다."
                            )
                        )
                        .padding(.vertical, 20)
                    } else {
                        ForEach(dayTravelGroups) { group in
                            travelInferenceCard(group)
                                .onTapGesture {
                                    selectedGroupID = group.id
                                }
                                .accessibilityAddTraits(.isButton)
                        }
                        ForEach(dayFloors) { floor in
                            floorInferenceCard(floor)
                        }
                    }

                    Label(
                        "iPhone GPS·모션·기압이 기본 · Apple Watch 운동·경로·활동 데이터는 권한을 받은 경우에만 보조",
                        systemImage: "applewatch"
                    )
                    .font(.taption(size: 7.5))
                    .foregroundStyle(Color.tpSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    privacyCard
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 12)
            }
            .background(Color.tpBackground)
        }
        .onAppear {
            selectedGroupID =
                dayTravelGroups.first(where: { !$0.isConfirmed })?.id
                ?? dayTravelGroups.first?.id
            for floor in dayFloors {
                floorOverrides[floor.id] =
                    floor.toFloor ?? floor.fromFloor ?? 0
            }
        }
        .task(id: model.selectedDate) {
            routeReadings = await model.sensorReadings(in: daySpan)
            fitMapToSelection()
        }
        .onChange(of: selectedGroupID) { _, _ in
            fitMapToSelection()
        }
    }

    private func travelInferenceCard(
        _ group: TravelSegmentGroup
    ) -> some View {
        VStack(spacing: TaptionSpacing.cozy) {
            HStack(spacing: TaptionSpacing.cozy) {
                Image(systemName: group.mode.outlineSymbolName)
                    .accessibilityHidden(true)
                    .font(.taption(size: 15))
                    .foregroundStyle(Color.tpTransitDark)
                    .frame(width: 29, height: 29)
                    .background(
                        Color.tpTransit,
                        in: RoundedRectangle(cornerRadius: TaptionRadius.control)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(
                        "\(group.span.start.formatted(date: .omitted, time: .shortened))–\(group.span.end.formatted(date: .omitted, time: .shortened))"
                    )
                        .font(.taption(size: 8))
                        .foregroundStyle(Color.tpSecondary)
                    Text(
                        "\(group.mode.displayName) · \(group.span.duration.shortDuration)"
                    )
                        .font(.taption(size: 11, weight: .bold))
                }
                Spacer()
                Text(
                    group.isConfirmed
                        ? "확인됨"
                        : group.confirmedCount > 0
                            ? "일부 확인"
                            : group.confidence.displayName
                )
                    .font(.taption(size: 7.5, weight: .black))
                    .foregroundStyle(
                        group.confidence == .high
                            ? Color(red: 0.18, green: 0.46, blue: 0.28)
                            : Color(red: 0.61, green: 0.41, blue: 0.11)
                    )
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        group.confidence == .high
                            ? Color(red: 0.92, green: 0.96, blue: 0.93)
                            : Color.tpWarningTint,
                        in: RoundedRectangle(cornerRadius: TaptionRadius.tight)
                    )
            }

            if group.segments.count > 1 {
                HStack(spacing: TaptionSpacing.compact) {
                    Image(systemName: "square.stack.3d.up")
                    Text("이어진 유사 경로 \(group.segments.count)개를 한 번에 표시")
                    Spacer()
                    if group.distanceMeters > 0 {
                        Text(formattedDistance(group.distanceMeters))
                    }
                }
                .font(.taption(size: 7.5, weight: .bold))
                .foregroundStyle(Color.tpTransitDark)
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .background(
                    Color.tpTransit.opacity(0.58),
                    in: RoundedRectangle(cornerRadius: TaptionRadius.small)
                )
            }

            if !group.evidence.isEmpty {
                VStack(alignment: .leading, spacing: TaptionSpacing.tight) {
                    Text("판정 근거")
                        .font(.taption(size: 7.5, weight: .bold))
                        .foregroundStyle(Color.tpSecondary)
                    ChipFlowLayout(spacing: TaptionSpacing.tight) {
                        ForEach(group.evidence, id: \.self) { signal in
                            signalChip(signal)
                        }
                    }
                }
            }

            HStack(spacing: TaptionSpacing.snug) {
                if group.isConfirmed {
                    Button("자동 판정으로 되돌리기") {
                        model.forgetTravelConfirmations(group.segmentIDs)
                    }
                    .foregroundStyle(Color.tpSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(
                        Color.tpControlFill,
                        in: RoundedRectangle(cornerRadius: TaptionRadius.control)
                    )
                } else {
                    Button("맞아요") {
                        model.confirmTravel(
                            group.segmentIDs,
                            mode: group.mode
                        )
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(
                        Color.tpInk,
                        in: RoundedRectangle(cornerRadius: TaptionRadius.control)
                    )
                }
                Button("다른 수단") {
                    selectedGroupID = group.id
                }
                .foregroundStyle(Color.tpSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(
                    Color.tpControlFill,
                    in: RoundedRectangle(cornerRadius: TaptionRadius.control)
                )
            }
            .font(.taption(size: 8.5, weight: .bold))
            .buttonStyle(.plain)
        }
        .padding(10)
        .draftCard()
        .overlay {
            if selectedGroupID == group.id {
                RoundedRectangle(cornerRadius: TaptionRadius.card)
                    .stroke(Color.tpTransitDark, lineWidth: 2)
            }
        }
    }

    private func floorInferenceCard(
        _ floor: FloorTransition
    ) -> some View {
        VStack(spacing: TaptionSpacing.cozy) {
            HStack(spacing: TaptionSpacing.cozy) {
                Image(systemName: "building.2")
                    .accessibilityHidden(true)
                    .font(.taption(size: 15))
                    .foregroundStyle(Color.tpPlaceDark)
                    .frame(width: 29, height: 29)
                    .background(
                        Color.tpPlace,
                        in: RoundedRectangle(cornerRadius: TaptionRadius.control)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(
                        floor.span.end.formatted(
                            date: .omitted,
                            time: .shortened
                        )
                    )
                    .font(.taption(size: 8))
                    .foregroundStyle(Color.tpSecondary)
                    Text(
                        "\(floor.fromFloor.map { "\($0)층" } ?? "기준층 미확인") → \(floorOverrides[floor.id] ?? floor.toFloor ?? 0)층"
                    )
                    .font(.taption(size: 11, weight: .bold))
                }
                Spacer()
                Text(floor.confidence.displayName)
                    .font(.taption(size: 7.5, weight: .black))
                    .foregroundStyle(
                        floor.confidence == .high
                            ? Color(red: 0.18, green: 0.46, blue: 0.28)
                            : Color(red: 0.61, green: 0.41, blue: 0.11)
                    )
            }

            ChipFlowLayout(spacing: TaptionSpacing.tight) {
                ForEach(floor.evidence, id: \.self) { signal in
                    signalChip(signal)
                }
            }

            HStack(spacing: TaptionSpacing.snug) {
                Button {
                    floorOverrides[floor.id, default: 0] -= 1
                } label: {
                    Image(systemName: "minus")
                }
                .accessibilityLabel("층 내리기")
                Text("\(floorOverrides[floor.id] ?? floor.toFloor ?? 0)층")
                    .font(.taption(size: 10, weight: .black))
                    .frame(maxWidth: .infinity)
                Button {
                    floorOverrides[floor.id, default: 0] += 1
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("층 올리기")
                Button("이 층으로 확인") {
                    model.confirmFloorTransition(
                        floor.id,
                        toFloor:
                            floorOverrides[floor.id]
                            ?? floor.toFloor
                    )
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    Color.tpInk,
                    in: RoundedRectangle(cornerRadius: TaptionRadius.control)
                )
            }
            .font(.taption(size: 8.5, weight: .bold))
            .buttonStyle(.plain)
        }
        .padding(10)
        .draftCard()
    }

    private func signalChip(_ signal: String) -> some View {
        Text(signal)
            .font(.taption(size: 7.5, weight: .semibold))
            .foregroundStyle(Color.tpSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(
                Color.tpControlFill,
                in: RoundedRectangle(cornerRadius: TaptionRadius.tight)
            )
    }

    private var routeMapCard: some View {
        VStack(spacing: TaptionSpacing.regular) {
            HStack(spacing: TaptionSpacing.snug) {
                Image(systemName: "map")
                    .foregroundStyle(Color.tpTransitDark)
                VStack(alignment: .leading, spacing: 1) {
                    Text("오늘 이동 경로")
                        .font(.taption(size: 10, weight: .bold))
                    Text("구간을 누르면 해당 경로를 강조합니다")
                        .font(.taption(size: 7.5))
                        .foregroundStyle(Color.tpSecondary)
                }
                Spacer()
                Text("\(dayTravelGroups.count)개 묶음")
                    .font(.taption(size: 7.5, weight: .bold))
                    .foregroundStyle(Color.tpTransitDark)
            }

            if allRouteCoordinates.isEmpty {
                VStack(spacing: TaptionSpacing.snug) {
                    Image(systemName: "location.slash")
                        .font(.taption(size: 18))
                    Text("저장된 GPS 좌표가 있는 경로부터 지도에 표시됩니다")
                        .font(.taption(size: 8, weight: .semibold))
                }
                .foregroundStyle(Color.tpSecondary)
                .frame(maxWidth: .infinity, minHeight: 105)
                .background(
                    Color.tpBackground,
                    in: RoundedRectangle(cornerRadius: TaptionRadius.compact)
                )
            } else {
                Map(position: $mapPosition, content: {
                    ForEach(dayTravelGroups) { group in
                        let coordinates = coordinates(for: group)
                        if coordinates.count >= 2 {
                            MapPolyline(coordinates: coordinates)
                                .stroke(
                                    group.mode.routeColor.opacity(
                                        selectedGroupID == group.id
                                            ? 1
                                            : RouteMapLineStyle.minimumOpacity
                                    ),
                                    style: StrokeStyle(
                                        lineWidth: RouteMapLineStyle.lineWidth,
                                        lineCap: .round,
                                        lineJoin: .round
                                    )
                                )
                        }
                    }
                    if let group = selectedGroup,
                       let start = coordinates(for: group).first {
                        Marker("출발", systemImage: "circle.fill", coordinate: start)
                            .tint(group.mode.routeColor)
                    }
                    if let group = selectedGroup,
                       let end = coordinates(for: group).last,
                       coordinates(for: group).count >= 2 {
                        Marker("도착", systemImage: "mappin", coordinate: end)
                            .tint(group.mode.routeColor)
                    }
                })
                .mapStyle(.standard(
                    elevation: .flat,
                    emphasis: .muted,
                    pointsOfInterest: .excludingAll,
                    showsTraffic: false
                ))
                .environment(\.colorScheme, .light)
                .frame(height: 165)
                .background {
                    GeometryReader { geometry in
                        Color.clear
                            .onAppear {
                                updateRouteMapViewportSize(geometry.size)
                            }
                            .onChange(of: geometry.size) { _, size in
                                updateRouteMapViewportSize(size)
                            }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: TaptionRadius.compact))
            }

            HStack(spacing: TaptionSpacing.cozy) {
                if let selectedGroup {
                    Label(
                        "\(selectedGroup.mode.displayName) · \(selectedGroup.span.duration.shortDuration)",
                        systemImage: selectedGroup.mode.outlineSymbolName
                    )
                    .font(.taption(size: 8, weight: .bold))
                    .foregroundStyle(Color.tpSecondary)
                    .lineLimit(1)
                } else {
                    Text("경로를 선택해 주세요")
                        .font(.taption(size: 8))
                        .foregroundStyle(Color.tpSecondary)
                }
                Spacer()
                Button {
                    guard let selectedGroup else { return }
                    openInAppleMaps(selectedGroup)
                } label: {
                    Label("Apple 지도", systemImage: "arrow.up.right.square")
                        .font(.taption(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 7)
                        .background(
                            Color.tpInk,
                            in: RoundedRectangle(cornerRadius: TaptionRadius.control)
                        )
                }
                .buttonStyle(.plain)
                .disabled(
                    selectedGroup.map { coordinates(for: $0).isEmpty }
                        ?? true
                )
                .opacity(
                    selectedGroup.map { coordinates(for: $0).isEmpty }
                        == false ? 1 : 0.42
                )
            }
        }
        .padding(9)
        .draftCard()
    }

    private var allRouteCoordinates: [CLLocationCoordinate2D] {
        dayTravelGroups.flatMap(coordinates(for:))
    }

    private func routePoints(for group: TravelSegmentGroup) -> [GeoPoint] {
        var points: [GeoPoint] = []
        if let fromPlaceID = group.fromPlaceID,
           let point = model.snapshot.places.first(where: {
               $0.id == fromPlaceID
           })?.point {
            points.append(point)
        }
        points.append(contentsOf: model.mergingLiveSensorReadings(
            routeReadings,
            in: daySpan
        )
            .filter {
                RouteTimelineTimestamp.isValid($0.timestamp)
                    && group.span.contains($0.timestamp)
            }
            .sorted { $0.timestamp < $1.timestamp }
            .compactMap(\.point)
            .filter { $0.horizontalAccuracy <= 200 }
        )
        if let toPlaceID = group.toPlaceID,
           let point = model.snapshot.places.first(where: {
               $0.id == toPlaceID
           })?.point {
            points.append(point)
        }

        return points.reduce(into: []) { result, point in
            guard let previous = result.last else {
                result.append(point)
                return
            }
            if distanceMeters(previous, point) >= 8 {
                result.append(point)
            }
        }
    }

    private func coordinates(
        for group: TravelSegmentGroup
    ) -> [CLLocationCoordinate2D] {
        routePoints(for: group).map {
            CLLocationCoordinate2D(
                latitude: $0.latitude,
                longitude: $0.longitude
            )
        }
    }

    private func fitMapToSelection() {
        let values: [CLLocationCoordinate2D]
        if let selectedGroup {
            values = coordinates(for: selectedGroup)
        } else {
            values = allRouteCoordinates
        }
        guard let region = RouteMapViewport.region(
            for: values,
            viewport: resolvedRouteMapViewportSize,
            padding: .compact
        ) else {
            mapPosition = .automatic
            return
        }
        mapPosition = .region(region)
    }

    private var resolvedRouteMapViewportSize: CGSize {
        guard routeMapViewportSize.width > 1,
              routeMapViewportSize.height > 1 else {
            return CGSize(width: 340, height: 165)
        }
        return routeMapViewportSize
    }

    private func updateRouteMapViewportSize(_ size: CGSize) {
        guard size.width > 1,
              size.height > 1,
              abs(routeMapViewportSize.width - size.width) > 0.5
                || abs(routeMapViewportSize.height - size.height) > 0.5
        else { return }
        routeMapViewportSize = size
        fitMapToSelection()
    }

    private func openInAppleMaps(_ group: TravelSegmentGroup) {
        let values = coordinates(for: group)
        guard let first = values.first else { return }
        let start = MKMapItem(placemark: MKPlacemark(coordinate: first))
        start.name = model.snapshot.places.first(where: {
            $0.id == group.fromPlaceID
        })?.displayName ?? "출발"

        guard values.count >= 2, let last = values.last else {
            start.openInMaps()
            return
        }
        let destination = MKMapItem(
            placemark: MKPlacemark(coordinate: last)
        )
        destination.name = model.snapshot.places.first(where: {
            $0.id == group.toPlaceID
        })?.displayName ?? "도착"
        var options: [String: Any] = [:]
        if let directionMode = group.mode.appleMapsDirectionsMode {
            options[MKLaunchOptionsDirectionsModeKey] = directionMode
        }
        if group.mode == .car || group.mode == .taxi || group.mode == .bus {
            options[MKLaunchOptionsShowsTrafficKey] = true
        }
        MKMapItem.openMaps(
            with: [start, destination],
            launchOptions: options
        )
    }

    private func formattedDistance(_ meters: Double) -> String {
        AppRegion.current.distanceText(meters: meters, compact: true)
    }

    private var daySpan: TimeSpan {
        TimelineAggregationEngine().interval(
            for: .day,
            containing: model.selectedDate
        )
    }

    private var dayTravel: [TravelSegment] {
        model.snapshot.travel.overlapping(daySpan, by: \.span)
    }

    private var dayTravelGroups: [TravelSegmentGroup] {
        TravelSegmentGroupingEngine.groups(from: dayTravel)
    }

    private var dayFloors: [FloorTransition] {
        model.snapshot.floorTransitions.overlapping(daySpan, by: \.span)
    }

    private var selectedGroup: TravelSegmentGroup? {
        guard let selectedGroupID else { return nil }
        return dayTravelGroups.first { $0.id == selectedGroupID }
    }

    private var privacyCard: some View {
        HStack(spacing: TaptionSpacing.snug) {
            Image(systemName: "lock")
                .font(.taption(size: 15))
                .foregroundStyle(Color.tpPlaceDark)
            VStack(alignment: .leading, spacing: 2) {
                Text("모르면 확정하지 않음")
                    .font(.taption(size: 9, weight: .bold))
                    .foregroundStyle(Color.tpInk)
                Text("‘차량 추정’ 또는 ‘층 미확인’으로 남기고 한 번 탭해 수정")
                    .font(.taption(size: 8))
                    .foregroundStyle(Color.tpSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(Color.tpCard, in: RoundedRectangle(cornerRadius: TaptionRadius.compact))
        .overlay {
            RoundedRectangle(cornerRadius: TaptionRadius.compact)
                .stroke(Color.tpControlStroke, lineWidth: 1)
        }
    }
}

private extension TravelMode {
    var displayName: String {
        MovementPresentation.title(for: self)
    }

    var appleMapsDirectionsMode: String? {
        switch self {
        case .walking, .running:
            MKLaunchOptionsDirectionsModeWalking
        case .cycling:
            MKLaunchOptionsDirectionsModeCycling
        case .bus, .subway, .train:
            MKLaunchOptionsDirectionsModeTransit
        case .taxi, .car:
            MKLaunchOptionsDirectionsModeDriving
        case .airplane, .ship:
            nil
        }
    }
}

private extension ConfidenceLevel {
    var displayName: String {
        switch self {
        case .low: "낮음"
        case .medium: "중간"
        case .high: "높음"
        }
    }
}

private extension TimeInterval {
    var shortDuration: String {
        let totalMinutes = max(0, Int((self / 60).rounded()))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours == 0 { return "\(minutes)분" }
        if minutes == 0 { return "\(hours)시간" }
        return "\(hours)시간 \(minutes)분"
    }
}
