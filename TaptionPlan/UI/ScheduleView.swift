import SwiftUI
import UIKit
import MapKit

private let scheduleLabelColumnWidth: CGFloat = 64
private let ganttTableLineColor = Color.tpLine.opacity(0.30)

private struct TimelineAxisMarker: Identifiable {
    let id: String
    let fraction: Double
    let label: String
    let isCurrent: Bool
    let holidayName: String?

    init(
        id: String,
        fraction: Double,
        label: String,
        isCurrent: Bool,
        holidayName: String? = nil
    ) {
        self.id = id
        self.fraction = fraction
        self.label = label
        self.isCurrent = isCurrent
        self.holidayName = holidayName
    }
}

private enum TimelineDetailSection: String, CaseIterable, Identifiable {
    case map = "지도"
    case action = "액션·메모"
    case photo = "사진"
    case event = "이벤트"
    case schedule = "일정"

    var id: Self { self }

    var systemImage: String {
        switch self {
        case .map: "map"
        case .action: "checklist.checked"
        case .photo: "photo.on.rectangle"
        case .event: "sparkles"
        case .schedule: "calendar"
        }
    }
}

private struct TimelineSelection: Equatable {
    let title: String
    let span: TimeSpan
    let planID: UUID?
    let actualID: UUID?
    let travelID: UUID?
    let isRoute: Bool
    let categoryID: String?
    let categoryName: String?

    init(
        title: String,
        span: TimeSpan,
        planID: UUID?,
        actualID: UUID? = nil,
        travelID: UUID? = nil,
        isRoute: Bool,
        categoryID: String? = nil,
        categoryName: String? = nil
    ) {
        self.title = title
        self.span = span
        self.planID = planID
        self.actualID = actualID
        self.travelID = travelID
        self.isRoute = isRoute
        self.categoryID = categoryID
        self.categoryName = categoryName
    }
}

@MainActor
private final class TimelinePlayheadDetailGate {
    private let minimumInterval: TimeInterval = 1.0 / 20.0
    private var lastDeliveryUptime: TimeInterval = -.infinity
    private var pendingDate: Date?
    private var scheduledTask: Task<Void, Never>?

    func submit(
        _ date: Date,
        deliver: @escaping @MainActor (Date) -> Void
    ) {
        pendingDate = date
        let now = ProcessInfo.processInfo.systemUptime
        let remaining = minimumInterval - (now - lastDeliveryUptime)
        if remaining <= 0 {
            scheduledTask?.cancel()
            scheduledTask = nil
            deliverPending(using: deliver)
            return
        }
        guard scheduledTask == nil else { return }
        scheduledTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(
                    nanoseconds: UInt64(max(0, remaining) * 1_000_000_000)
                )
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.scheduledTask = nil
            self.deliverPending(using: deliver)
        }
    }

    func cancel() {
        scheduledTask?.cancel()
        scheduledTask = nil
        pendingDate = nil
    }

    private func deliverPending(
        using deliver: @MainActor (Date) -> Void
    ) {
        guard let pendingDate else { return }
        self.pendingDate = nil
        lastDeliveryUptime = ProcessInfo.processInfo.systemUptime
        deliver(pendingDate)
    }
}

private extension TimelineSelection {
    var preferredDetailSection: TimelineDetailSection {
        if isRoute {
            return .map
        }
        switch categoryID {
        case "photo":
            return .photo
        case "event":
            return .event
        case "schedule", "calendar":
            return .schedule
        default:
            return .action
        }
    }
}

private extension PhotoCluster {
    var detailSpan: TimeSpan {
        let sortedDates = photos.map(\.capturedAt).sorted()
        let start = sortedDates.first ?? capturedAt
        let end = sortedDates.last ?? capturedAt
        return TimeSpan(
            start: start,
            end: max(start.addingTimeInterval(60), end)
        )
    }
}

struct TwoFingerDoubleTapAttachment: UIViewRepresentable {
    let onRecognized: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onRecognized: onRecognized)
    }

    func makeUIView(context: Context) -> AttachmentView {
        let view = AttachmentView()
        view.isUserInteractionEnabled = false
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(
        _ uiView: AttachmentView,
        context: Context
    ) {
        context.coordinator.onRecognized = onRecognized
        uiView.installRecognizerIfNeeded()
    }

    static func dismantleUIView(
        _ uiView: AttachmentView,
        coordinator: Coordinator
    ) {
        uiView.removeRecognizer()
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onRecognized: () -> Void

        init(onRecognized: @escaping () -> Void) {
            self.onRecognized = onRecognized
        }

        @objc func didRecognize() {
            onRecognized()
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith
                otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }

    final class AttachmentView: UIView {
        weak var coordinator: Coordinator?
        private weak var installedSuperview: UIView?
        private var recognizer: UITapGestureRecognizer?

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            installRecognizerIfNeeded()
        }

        func installRecognizerIfNeeded() {
            guard let superview, let coordinator else { return }
            if installedSuperview === superview, recognizer != nil {
                return
            }
            removeRecognizer()
            let recognizer = UITapGestureRecognizer(
                target: coordinator,
                action: #selector(Coordinator.didRecognize)
            )
            recognizer.numberOfTapsRequired = 2
            recognizer.numberOfTouchesRequired = 2
            recognizer.cancelsTouchesInView = false
            recognizer.delegate = coordinator
            superview.addGestureRecognizer(recognizer)
            installedSuperview = superview
            self.recognizer = recognizer
        }

        func removeRecognizer() {
            if let recognizer {
                installedSuperview?.removeGestureRecognizer(recognizer)
            }
            recognizer = nil
            installedSuperview = nil
        }
    }
}

struct ScheduleView: View {
    @Bindable var model: AppModel
    @State private var dayZoom: TimelineZoomPreset = .oneDay
    @State private var selectedTimelineItem: TimelineSelection?
    @State private var detailSection: TimelineDetailSection = .map
    @State private var selectedPhotoCluster: PhotoCluster?
    @State private var routeReadings: [SensorReading] = []
    @State private var editingPlanID: UUID?
    @State private var mapPlayheadDate: Date?
    @State private var playheadDetailGate = TimelinePlayheadDetailGate()

    var body: some View {
        VStack(spacing: 0) {
            DraftTopBar(
                title: headerTitle,
                trailing: headerTrailing,
                selectedScale: model.selectedScale,
                onScaleChange: { model.selectScale($0) },
                dayZoom: dayZoom,
                onDayZoomChange: { dayZoom = $0 },
                onTitleTap: { model.returnToNow() },
                onPrevious: { model.shiftSelectedDate(by: -1) },
                onNext: { model.shiftSelectedDate(by: 1) },
                isPreviousEnabled: model.canShiftToPreviousPeriod,
                isNextEnabled: model.canShiftToNextPeriod
            )
            .simultaneousGesture(
                TapGesture().onEnded {
                    editingPlanID = nil
                }
            )
            TimelineBoard(
                model: model,
                scale: model.selectedScale,
                storedPlans: model.snapshot.plans,
                dayZoom: $dayZoom,
                editingPlanID: $editingPlanID,
                onPlayheadMove: { date in
                    requestPlayheadDetailUpdate(at: date)
                },
                onSelection: { selection in
                    playheadDetailGate.cancel()
                    mapPlayheadDate = nil
                    selectedTimelineItem = selection
                    selectedPhotoCluster = nil
                    detailSection = selection.preferredDetailSection
                },
                onFocus: { selection in
                    playheadDetailGate.cancel()
                    mapPlayheadDate = nil
                    selectedTimelineItem = selection
                    selectedPhotoCluster = nil
                    detailSection = selection.preferredDetailSection
                },
                onPhotoSelection: { cluster in
                    playheadDetailGate.cancel()
                    editingPlanID = nil
                    mapPlayheadDate = nil
                    selectedPhotoCluster = cluster
                    selectedTimelineItem = TimelineSelection(
                        title: "사진",
                        span: cluster.detailSpan,
                        planID: nil,
                        isRoute: false,
                        categoryID: "photo",
                        categoryName: "사진"
                    )
                    detailSection = .photo
                }
            )
            Spacer(minLength: 0)
                .contentShape(Rectangle())
                .onTapGesture {
                    editingPlanID = nil
                }
            TimelineDetailPanel(
                model: model,
                selection: selectedTimelineItem,
                playheadDate: mapPlayheadDate,
                section: $detailSection,
                highlightedSection: selectedTimelineItem?.preferredDetailSection,
                selectedPhotoCluster: $selectedPhotoCluster,
                routeReadings: routeReadings,
                onActualDeleted: { actualID in
                    if selectedTimelineItem?.actualID == actualID {
                        selectedTimelineItem = nil
                    }
                }
            )
            .simultaneousGesture(
                TapGesture().onEnded {
                    editingPlanID = nil
                }
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.white)
        .task(id: routeReadingsSpan) {
            routeReadings = await model.sensorReadings(in: routeReadingsSpan)
        }
        .onDisappear {
            playheadDetailGate.cancel()
        }
    }

    private func requestPlayheadDetailUpdate(at date: Date) {
        playheadDetailGate.submit(date) { deliveredDate in
            mapPlayheadDate = deliveredDate
            focusMapOnPlayhead(at: deliveredDate)
        }
    }

    private func focusMapOnPlayhead(at date: Date) {
        guard let selection = timelineSelection(at: date) else {
            selectedPhotoCluster = nil
            selectedTimelineItem = TimelineSelection(
                title: "현재 위치",
                span: playheadFocusSpan(around: date),
                planID: nil,
                isRoute: true,
                categoryID: "movement",
                categoryName: "이동"
            )
            return
        }

        selectedTimelineItem = selection
        if selection.categoryID != "photo" {
            selectedPhotoCluster = nil
        }
    }

    private func timelineSelection(at date: Date) -> TimelineSelection? {
        if let cluster = photoCluster(at: date) {
            selectedPhotoCluster = cluster
            return TimelineSelection(
                title: "사진",
                span: cluster.detailSpan,
                planID: nil,
                isRoute: false,
                categoryID: "photo",
                categoryName: "사진"
            )
        }

        if let travel = model.snapshot.travel.first(where: {
            $0.span.contains(date)
        }) {
            return TimelineSelection(
                title: timelineTravelModeName(travel.mode),
                span: travel.span,
                planID: nil,
                travelID: travel.id,
                isRoute: true,
                categoryID: "movement",
                categoryName: "이동"
            )
        }

        if let event = model.snapshot.plans.first(where: {
            $0.span.contains(date)
                && $0.categoryID == "event"
                && $0.parentID == nil
        }) {
            return TimelineSelection(
                title: event.title,
                span: event.span,
                planID: event.id,
                isRoute: false,
                categoryID: "event",
                categoryName: "이벤트"
            )
        }

        if let calendarEvent = model.snapshot.calendarEvents.first(where: {
            $0.span.contains(date)
        }) {
            return TimelineSelection(
                title: calendarEvent.title,
                span: calendarEvent.span,
                planID: nil,
                isRoute: false,
                categoryID: "calendar",
                categoryName: "일정"
            )
        }

        if let plan = model.snapshot.plans.first(where: {
            $0.span.contains(date)
                && $0.categoryID != "event"
                && $0.parentID == nil
        }) {
            return TimelineSelection(
                title: plan.title,
                span: plan.span,
                planID: plan.id,
                isRoute: false,
                categoryID: plan.categoryID,
                categoryName: categoryName(for: plan.categoryID)
            )
        }

        return nil
    }

    private func categoryName(for categoryID: String) -> String? {
        model.snapshot.categories.first { $0.id == categoryID }?.name
    }

    private func photoCluster(at date: Date) -> PhotoCluster? {
        PhotoClusterer.nearestCluster(
            to: date,
            in: model.snapshot.photos,
            tolerance: photoPlayheadTolerance
        )
    }

    private var photoPlayheadTolerance: TimeInterval {
        guard model.selectedScale == .day else {
            return 24 * 60 * 60
        }
        return min(
            25 * 60,
            max(60, dayZoom.duration * 0.035)
        )
    }

    private var headerTitle: String {
        ScheduleHeaderFormatter().title(
            for: model.selectedDate,
            scale: model.selectedScale
        )
    }

    private var headerTrailing: String {
        switch model.selectedScale {
        case .day:
            if let weather = closestWeather {
                "\(weather.temperatureCelsius.rounded().formatted())° · \(weather.condition)"
            } else {
                ""
            }
        case .week:
            "W\(Calendar.autoupdatingCurrent.component(.weekOfYear, from: model.selectedDate))"
        case .month:
            "\(Calendar.autoupdatingCurrent.range(of: .day, in: .month, for: model.selectedDate)?.count ?? 30)일"
        case .year: "나의 한 해"
        }
    }

    private var visibleSpan: TimeSpan {
        TimelineAggregationEngine().interval(
            for: model.selectedScale.timelineLevel,
            containing: model.selectedDate
        )
    }

    private var daySpan: TimeSpan {
        TimelineAggregationEngine().interval(
            for: .day,
            containing: model.selectedDate
        )
    }

    private var routeReadingsSpan: TimeSpan {
        if mapPlayheadDate != nil {
            return daySpan
        }
        return selectedTimelineItem?.span ?? daySpan
    }

    private var closestWeather: WeatherContext? {
        model.snapshot.weather
            .filter { visibleSpan.contains($0.observedAt) }
            .min {
                abs($0.observedAt.timeIntervalSince(model.selectedDate))
                    < abs($1.observedAt.timeIntervalSince(model.selectedDate))
            }
    }
}

private func playheadFocusSpan(around date: Date) -> TimeSpan {
    TimeSpan(
        start: date.addingTimeInterval(-15 * 60),
        end: date.addingTimeInterval(15 * 60)
    )
}

private func timelineTravelModeName(_ mode: TravelMode) -> String {
    switch mode {
    case .walking: "걷기"
    case .running: "달리기"
    case .cycling: "자전거"
    case .bus: "버스"
    case .subway: "지하철"
    case .taxi: "택시"
    case .car: "자가용"
    case .train: "기차"
    case .airplane: "비행기"
    case .ship: "배"
    }
}

enum TimelineRouteDisplayPolicy {
    static func segments(
        from travel: [TravelSegment],
        intersecting activeSpan: TimeSpan,
        at playheadDate: Date?,
        selectedTravelID: UUID? = nil
    ) -> [TravelSegment] {
        if let selectedTravelID {
            return travel.filter { $0.id == selectedTravelID }
        }
        if let playheadDate {
            return travel.filter { $0.span.contains(playheadDate) }
        }
        return travel.filter {
            $0.span.intersection(with: activeSpan) != nil
        }
    }

    static func allowsFallbackPath(
        at playheadDate: Date?,
        routeSegments: [TravelSegment]
    ) -> Bool {
        playheadDate == nil || !routeSegments.isEmpty
    }
}

private struct TimelineDetailPanel: View {
    @Bindable var model: AppModel
    let selection: TimelineSelection?
    let playheadDate: Date?
    @Binding var section: TimelineDetailSection
    let highlightedSection: TimelineDetailSection?
    @Binding var selectedPhotoCluster: PhotoCluster?
    let routeReadings: [SensorReading]
    let onActualDeleted: (UUID) -> Void
    @State private var mapPosition: MapCameraPosition = .automatic
    @State private var selectedPhotoIndex = 0
    @State private var pendingActualDeletionID: UUID?
    @State private var lastMapFocusCoordinate: CLLocationCoordinate2D?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(TimelineDetailSection.allCases) { item in
                        let isSelected = section == item
                        let isHighlighted = highlightedSection == item
                        Button {
                            section = item
                        } label: {
                            Label(item.rawValue, systemImage: item.systemImage)
                                .font(.taption(size: 9, weight: isSelected || isHighlighted ? .bold : .regular))
                                .foregroundStyle(
                                    isSelected
                                        ? Color.white
                                        : isHighlighted
                                            ? Color.tpInk
                                            : Color.tpSecondary
                                )
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .background(
                                    isSelected ? Color.tpInk : Color.clear,
                                    in: Capsule()
                                )
                                .overlay {
                                    if isHighlighted && !isSelected {
                                        Capsule()
                                            .stroke(
                                                Color.tpInk.opacity(0.24),
                                                lineWidth: 0.75
                                            )
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(
                            isSelected ? .isSelected : []
                        )
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
            }
            .background(Color(red: 0.94, green: 0.94, blue: 0.95))

            Group {
                switch section {
                case .map:
                    routeContent
                case .action:
                    actionContent
                case .photo:
                    photoContent
                case .event:
                    eventContent
                case .schedule:
                    scheduleContent
                }
            }
            .frame(maxWidth: .infinity, minHeight: 264, maxHeight: 340, alignment: .top)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.tpBackground)
        }
        .overlay(alignment: .top) {
            Rectangle().fill(Color.tpLine).frame(height: 0.5)
        }
        .onChange(of: selection) { _, _ in
            fitMapToRoutes()
            selectedPhotoIndex = 0
        }
        .onChange(of: playheadDate) { _, _ in
            fitMapToRoutes()
        }
        .onChange(of: routeReadings) { _, _ in
            fitMapToRoutes()
        }
        .onChange(of: selectedPhotoCluster?.id) { _, _ in
            selectedPhotoIndex = 0
        }
        .task {
            fitMapToRoutes()
        }
        .confirmationDialog(
            "이 실제 기록을 삭제할까요?",
            isPresented: Binding(
                get: { pendingActualDeletionID != nil },
                set: { if !$0 { pendingActualDeletionID = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("실제 기록 삭제", role: .destructive) {
                guard let actualID = pendingActualDeletionID else { return }
                pendingActualDeletionID = nil
                Task {
                    await model.deleteActual(actualID)
                    onActualDeleted(actualID)
                }
            }
            Button("취소", role: .cancel) {
                pendingActualDeletionID = nil
            }
        } message: {
            Text("이 기록만 삭제되며 연결된 계획은 그대로 유지됩니다.")
        }
    }

    private var routeContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(
                    routeTitle,
                    systemImage: "map"
                )
                .font(.taption(size: 10, weight: .bold))
                .foregroundStyle(Color.tpTransitDark)
                Spacer()
                Text(isPlayheadLocationOnly ? "Apple 지도 위치" : "Apple 지도 경로")
                    .font(.taption(size: 8))
                    .foregroundStyle(Color.tpSecondary)
            }
            if let travel = explicitlySelectedTravel {
                travelModeEditor(for: travel)
            }
            if !hasMapContent {
                Label("기록된 이동 경로가 없습니다", systemImage: "location.slash")
                    .font(.taption(size: 9, weight: .semibold))
                    .foregroundStyle(Color.tpSecondary)
                    .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                Map(position: $mapPosition, content: {
                    ForEach(routeLocationPins) { pin in
                        Marker(pin.title, systemImage: "mappin.circle.fill", coordinate: pin.coordinate)
                            .tint(pin.tint)
                    }

                    if let pin = playheadRoutePin {
                        Marker(pin.title, systemImage: "scope", coordinate: pin.coordinate)
                            .tint(Color.tpNow)
                    }

                    ForEach(routeSegments) { segment in
                        let coordinates = coordinates(for: segment)
                        if coordinates.count >= 2 {
                            MapPolyline(coordinates: coordinates)
                                .stroke(
                                    routeColor(for: segment.mode).opacity(
                                        selectedSegmentIDs.contains(segment.id) ? 1 : 0.44
                                    ),
                                    style: StrokeStyle(
                                        lineWidth: selectedSegmentIDs.contains(segment.id) ? 4 : 2.5,
                                        lineCap: .round,
                                        lineJoin: .round
                                    )
                                )
                        }
                    }
                    if allowsFallbackRoutePath,
                       routeSegments.isEmpty,
                       fallbackRouteCoordinates.count >= 2 {
                        MapPolyline(coordinates: fallbackRouteCoordinates)
                            .stroke(
                                Color.tpTransitDark.opacity(0.45),
                                style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
                            )
                    }
                    if let selected = selectedSegment {
                        let coordinates = coordinates(for: selected)
                        if let first = coordinates.first {
                            Marker("출발", systemImage: "figure.walk", coordinate: first)
                                .tint(routeColor(for: selected.mode))
                        }
                        if coordinates.count >= 2, let last = coordinates.last {
                            Marker("도착", systemImage: "flag.fill", coordinate: last)
                                .tint(routeColor(for: selected.mode))
                        }
                    }
                })
                .mapStyle(.standard)
                .frame(height: 216)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            if isPlayheadLocationOnly {
                Text("이동 내용이 없어 현재 위치만 표시합니다.")
                    .font(.taption(size: 7.5, weight: .semibold))
                    .foregroundStyle(Color.tpSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Color(red: 0.98, green: 0.98, blue: 0.98),
                        in: Capsule()
                    )
            }

            if !routeSegments.isEmpty &&
                routeSegments.flatMap(coordinates(for:)).count < 2 {
                Text("좌표 정밀도가 낮아 선분을 그릴 수 없어서 위치 마커만 표시 중입니다.")
                    .font(.taption(size: 7.5, weight: .semibold))
                    .foregroundStyle(Color.tpSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Color(red: 0.98, green: 0.98, blue: 0.98),
                        in: Capsule()
                    )
            }
        }
    }

    private var memoContent: some View {
        VStack(alignment: .leading, spacing: 7) {
            detailHeading("메모", systemImage: "note.text")
            if let planID = selection?.planID {
                let memos = model.memos(for: planID)
                if memos.isEmpty {
                    Text("아직 메모가 없습니다")
                        .font(.taption(size: 9))
                        .foregroundStyle(Color.tpSecondary)
                } else {
                    ForEach(memos.prefix(3)) { memo in
                        Text("• \(memo.text)")
                            .font(.taption(size: 9))
                            .lineLimit(2)
                    }
                }
                Button("메모 열기") { model.openMemo(for: planID) }
                    .font(.taption(size: 9, weight: .bold))
                    .buttonStyle(.borderedProminent)
                    .tint(.tpInk)
            } else {
                Text("액션 아이템을 선택하면 메모가 표시됩니다")
                    .font(.taption(size: 9))
                    .foregroundStyle(Color.tpSecondary)
            }
        }
    }

    private var actionContent: some View {
        VStack(alignment: .leading, spacing: 7) {
            detailHeading("액션·메모", systemImage: "checklist.checked")
            if let actual = selectedActual {
                Text(actual.title)
                    .font(.taption(size: 14, weight: .bold))
                Text("\(actual.startedAt.formatted(date: .omitted, time: .shortened)) → \((actual.endedAt ?? .now).formatted(date: .omitted, time: .shortened))")
                    .font(.taption(size: 9))
                    .foregroundStyle(Color.tpSecondary)
                Text("실제 기록 · \(actualSourceLabel(actual.source))")
                    .font(.taption(size: 8.5, weight: .semibold))
                    .foregroundStyle(Color.tpSecondary)
                Button(role: .destructive) {
                    pendingActualDeletionID = actual.id
                } label: {
                    Label("실제 기록 삭제", systemImage: "trash")
                }
                .font(.taption(size: 9, weight: .bold))
                .buttonStyle(.bordered)
            } else if let selection,
               let planID = selection.planID,
               selection.categoryID != "calendar" {
                Text(selection.title)
                    .font(.taption(size: 14, weight: .bold))
                Text("\(selection.span.start.formatted(date: .omitted, time: .shortened)) → \(selection.span.end.formatted(date: .omitted, time: .shortened))")
                    .font(.taption(size: 9))
                    .foregroundStyle(Color.tpSecondary)
                actionMemoPreview(planID: planID)
                HStack(spacing: 8) {
                    Button("액션아이템 편집") {
                        model.planEditorRequest = PlanEditorRequest(id: planID)
                    }
                    Button("메모 추가") {
                        model.openMemo(for: planID)
                    }
                }
                .font(.taption(size: 9, weight: .bold))
                .buttonStyle(.borderedProminent)
                .tint(.tpInk)
            } else {
                Text("액션아이템을 선택하면 메모가 표시됩니다")
                    .font(.taption(size: 9))
                    .foregroundStyle(Color.tpSecondary)
            }
        }
    }

    private var selectedActual: ActualRecord? {
        guard let actualID = selection?.actualID else { return nil }
        return model.snapshot.actuals.first { $0.id == actualID }
    }

    private func actualSourceLabel(_ source: ActualSource) -> String {
        switch source {
        case .timer: "타이머"
        case .manual: "직접 기록"
        case .healthKit: "Apple 건강"
        case .appleWatch: "Apple Watch"
        case .calendar: "캘린더"
        case .location: "위치"
        case .photo: "사진"
        }
    }

    private func actionMemoPreview(planID: UUID) -> some View {
        let memos = model.memos(for: planID)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: "note.text")
                    .font(.taption(size: 8.5, weight: .bold))
                Text("메모 \(memos.count)개")
                    .font(.taption(size: 9, weight: .bold))
                Spacer()
                if !memos.isEmpty {
                    Button("전체 보기") {
                        model.openMemo(for: planID)
                    }
                    .font(.taption(size: 8.5, weight: .bold))
                    .foregroundStyle(Color.tpSecondary)
                    .buttonStyle(.plain)
                }
            }
            .foregroundStyle(Color.tpSecondary)

            if memos.isEmpty {
                Text("아직 메모가 없습니다. 결정, 아이디어, 막힘, 다음 할 일을 이 액션에 바로 붙여둘 수 있습니다.")
                    .font(.taption(size: 8.5))
                    .foregroundStyle(Color.tpSecondary)
                    .lineLimit(2)
            } else {
                ForEach(memos.prefix(2)) { memo in
                    Text("• \(memo.text)")
                        .font(.taption(size: 9))
                        .foregroundStyle(Color.tpInk.opacity(0.78))
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(
            Color.white.opacity(0.78),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.tpLine.opacity(0.7), lineWidth: 0.5)
        }
    }

    private var eventContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            detailHeading("이벤트", systemImage: "sparkles")
            let events = model.snapshot.plans.filter {
                $0.span.intersection(with: selection?.span ?? daySpan) != nil
                    && $0.categoryID == "event"
                    && $0.parentID == nil
            }
            if events.isEmpty {
                Text("선택한 시간의 이벤트가 없습니다")
                    .font(.taption(size: 9))
                    .foregroundStyle(Color.tpSecondary)
            } else {
                ForEach(events.prefix(4)) { event in
                    HStack {
                        Text(event.title).font(.taption(size: 9, weight: .semibold))
                        Spacer()
                        Text(event.span.start.formatted(date: .omitted, time: .shortened))
                            .font(.taption(size: 8))
                            .foregroundStyle(Color.tpSecondary)
                    }
                }
            }
            Text("애플·구글 캘린더에서 가져온 내용은 ‘일정’ 탭에 표시됩니다.")
                .font(.taption(size: 7.5, weight: .semibold))
                .foregroundStyle(Color.tpSecondary)
        }
    }

    private var photoContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                detailHeading("사진", systemImage: "photo.on.rectangle")
                Spacer()
                if let cluster = activePhotoCluster {
                    Text("\(selectedPhotoIndex + 1) / \(cluster.photos.count)")
                        .font(.taption(size: 8, weight: .semibold))
                        .foregroundStyle(Color.tpSecondary)
                }
            }

            if let cluster = activePhotoCluster {
                let photos = cluster.photos.sorted { $0.capturedAt < $1.capturedAt }
                TabView(selection: $selectedPhotoIndex) {
                    ForEach(Array(photos.enumerated()), id: \.element.id) { index, photo in
                        PhotoClusterPage(
                            model: model,
                            photo: photo,
                            index: index,
                            totalCount: photos.count
                        )
                        .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(height: 220)
                .background(
                    Color.black,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                Text(cluster.capturedAt.formatted(date: .omitted, time: .shortened))
                    .font(.taption(size: 8, weight: .semibold))
                    .foregroundStyle(Color.tpSecondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                ContentUnavailableView(
                    "선택한 시간의 사진이 없습니다",
                    systemImage: "photo"
                )
                .font(.taption(size: 9))
                .foregroundStyle(Color.tpSecondary)
                .frame(maxWidth: .infinity, minHeight: 220)
            }
        }
    }

    private var scheduleContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            detailHeading("일정", systemImage: "calendar")
            let calendarEvents = model.snapshot.calendarEvents.filter {
                $0.span.intersection(with: selection?.span ?? daySpan) != nil
            }
            if calendarEvents.isEmpty {
                Text("선택한 시간의 일정이 없습니다")
                    .font(.taption(size: 9))
                    .foregroundStyle(Color.tpSecondary)
            } else {
                ForEach(calendarEvents.prefix(4)) { event in
                    HStack(spacing: 7) {
                        Image(systemName: "calendar")
                            .font(.taption(size: 8, weight: .bold))
                            .foregroundStyle(Color.tpSecondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(event.title)
                                .font(.taption(size: 9, weight: .semibold))
                            Text(calendarSourceLabel(for: event))
                                .font(.taption(size: 7.5))
                                .foregroundStyle(Color.tpSecondary)
                        }
                        Spacer()
                        Text(calendarEventDateTimeLabel(for: event))
                            .font(.taption(size: 8))
                            .foregroundStyle(Color.tpSecondary)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
        }
    }

    private func calendarEventDateTimeLabel(for event: CalendarRecord) -> String {
        let date = calendarDateLabel(event.span.start)
        if event.isAllDay {
            return "\(date) · 종일"
        }
        let start = event.span.start.formatted(date: .omitted, time: .shortened)
        let end = event.span.end.formatted(date: .omitted, time: .shortened)
        return "\(date) · \(start)–\(end)"
    }

    private func calendarDateLabel(_ date: Date) -> String {
        let calendar = Calendar.autoupdatingCurrent
        let weekdaySymbols = ["일", "월", "화", "수", "목", "금", "토"]
        let month = calendar.component(.month, from: date)
        let day = calendar.component(.day, from: date)
        let weekdayIndex = max(
            0,
            min(
                weekdaySymbols.count - 1,
                calendar.component(.weekday, from: date) - 1
            )
        )
        return "\(month)월 \(day)일 (\(weekdaySymbols[weekdayIndex]))"
    }

    private func calendarSourceLabel(for event: CalendarRecord) -> String {
        let source = event.sourceTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let calendar = event.calendarTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if let source, !source.isEmpty, source != calendar {
            return "\(source) · \(calendar)"
        }
        return calendar.isEmpty ? "캘린더" : calendar
    }

    private func detailHeading(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.taption(size: 10, weight: .bold))
            .foregroundStyle(Color.tpInk)
    }

    private var daySpan: TimeSpan {
        TimelineAggregationEngine().interval(for: .day, containing: model.selectedDate)
    }

    private var activeRouteSpan: TimeSpan {
        if let playheadDate {
            return playheadFocusSpan(around: playheadDate)
        }
        return selection?.span ?? daySpan
    }

    private var activePhotoSpan: TimeSpan {
        selection?.span ?? daySpan
    }

    private var activePhotoCluster: PhotoCluster? {
        if let selectedPhotoCluster {
            return selectedPhotoCluster
        }
        return PhotoClusterer.cluster(
            model.snapshot.photos.filter {
                activePhotoSpan.contains($0.capturedAt)
            }
        ).first
    }

    private var routeTitle: String {
        if playheadDate != nil {
            return routeSegments.isEmpty
                ? "현재 위치"
                : "현재 이동 경로"
        }
        if selection?.isRoute == true {
            return "선택된 이동 경로"
        }
        if selection != nil {
            return "선택된 시간 경로"
        }
        return "오늘 이동 경로"
    }

    private var routeSegments: [TravelSegment] {
        TimelineRouteDisplayPolicy.segments(
            from: model.snapshot.travel,
            intersecting: activeRouteSpan,
            at: playheadDate,
            selectedTravelID: selection?.travelID
        )
    }

    private var explicitlySelectedTravel: TravelSegment? {
        guard playheadDate == nil, let travelID = selection?.travelID else {
            return nil
        }
        return model.snapshot.travel.first { $0.id == travelID }
    }

    private var selectedSegmentIDs: Set<UUID> {
        guard let selection, selection.isRoute else {
            return Set(routeSegments.map(\.id))
        }
        return Set(routeSegments.filter {
            $0.span.intersection(with: selection.span) != nil
        }.map(\.id))
    }

    private var selectedSegment: TravelSegment? {
        guard let selection, selection.isRoute else { return nil }
        return routeSegments.first {
            $0.span.intersection(with: selection.span) != nil
        }
    }

    private struct RouteLocationPin: Identifiable {
        let id: String
        let coordinate: CLLocationCoordinate2D
        let title: String
        let tint: Color
    }

    private var routeLocationPins: [RouteLocationPin] {
        if playheadDate != nil && routeSegments.isEmpty {
            return []
        }

        var pins: [RouteLocationPin] = []
        var usedPlaceIDs = Set<UUID>()
        let values = selectedSegment == nil ? routeSegments : routeSegments.filter {
            selectedSegmentIDs.contains($0.id)
        }

        for segment in values {
            func appendIfValid(_ placeID: UUID?, segmentMode: TravelMode) {
                guard let placeID else { return }
                guard usedPlaceIDs.insert(placeID).inserted else { return }
                guard
                    let place = model.snapshot.places.first(where: { $0.id == placeID }),
                    let point = place.point,
                    isValidCoordinate(point) else { return }
                pins.append(
                    RouteLocationPin(
                        id: placeID.uuidString,
                        coordinate: CLLocationCoordinate2D(
                            latitude: point.latitude,
                            longitude: point.longitude
                        ),
                        title: place.displayName,
                        tint: routeColor(for: segmentMode)
                    )
                )
            }

            appendIfValid(segment.fromPlaceID, segmentMode: segment.mode)
            appendIfValid(segment.toPlaceID, segmentMode: segment.mode)
        }

        if pins.isEmpty {
            if !routeSegments.isEmpty {
                for segment in values {
                    let values = coordinates(for: segment)
                    if let first = values.first {
                        pins.append(
                            RouteLocationPin(
                                id: "\(segment.id)-start",
                                coordinate: first,
                                title: "\(routeModeName(segment.mode)) 시작",
                                tint: routeColor(for: segment.mode),
                            )
                        )
                    }
                    if let last = values.last {
                        pins.append(
                            RouteLocationPin(
                                id: "\(segment.id)-end",
                                coordinate: last,
                                title: "\(routeModeName(segment.mode)) 종료",
                                tint: routeColor(for: segment.mode),
                            )
                        )
                    }
                }
            } else if let first = fallbackRouteCoordinates.first {
                let last = fallbackRouteCoordinates.last ?? first
                pins.append(
                    RouteLocationPin(
                        id: "fallback-start",
                        coordinate: first,
                        title: "측정 시작",
                        tint: .tpTransitDark
                    )
                )
                if fallbackRouteCoordinates.count >= 2 {
                    pins.append(
                        RouteLocationPin(
                            id: "fallback-end",
                            coordinate: last,
                            title: "측정 종료",
                            tint: .tpPlaceDark
                        )
                    )
                }
                if fallbackRouteCoordinates.count == 1 {
                    pins.append(
                        RouteLocationPin(
                            id: "fallback-standby",
                            coordinate: CLLocationCoordinate2D(
                                latitude: first.latitude + 0.00002,
                                longitude: first.longitude + 0.00002
                            ),
                            title: "추정 이동 위치",
                            tint: .tpPlaceDark
                        )
                    )
                }
            }
        }
        return pins
    }

    private var playheadRoutePin: RouteLocationPin? {
        guard let coordinate = playheadFocusCoordinate else { return nil }
        return RouteLocationPin(
            id: "playhead-focus",
            coordinate: coordinate,
            title: "플레이해드",
            tint: .tpNow
        )
    }

    private var allowsFallbackRoutePath: Bool {
        TimelineRouteDisplayPolicy.allowsFallbackPath(
            at: playheadDate,
            routeSegments: routeSegments
        )
    }

    private var isPlayheadLocationOnly: Bool {
        playheadDate != nil
            && routeSegments.isEmpty
            && playheadRoutePin != nil
    }

    private var hasMapContent: Bool {
        playheadRoutePin != nil
            || !routeLocationPins.isEmpty
            || !displayedRouteCoordinates.isEmpty
    }

    private var playheadFocusCoordinate: CLLocationCoordinate2D? {
        guard let playheadDate else { return nil }
        if let place = model.snapshot.places
            .filter({ $0.span.contains(playheadDate) })
            .min(by: {
                abs($0.span.start.timeIntervalSince(playheadDate))
                    < abs($1.span.start.timeIntervalSince(playheadDate))
            }),
           let point = place.point,
           isValidCoordinate(point) {
            return CLLocationCoordinate2D(
                latitude: point.latitude,
                longitude: point.longitude
            )
        }

        let nearestReadingPoint = routeReadings
            .filter { reading in
                guard let point = reading.point else { return false }
                return activeRouteSpan.contains(reading.timestamp)
                    && isValidCoordinate(point)
            }
            .min { lhs, rhs in
                abs(lhs.timestamp.timeIntervalSince(playheadDate))
                    < abs(rhs.timestamp.timeIntervalSince(playheadDate))
            }?
            .point

        if let point = nearestReadingPoint {
            return CLLocationCoordinate2D(
                latitude: point.latitude,
                longitude: point.longitude
            )
        }

        return routeSegments
            .filter { $0.span.contains(playheadDate) }
            .compactMap { coordinates(for: $0).first }
            .first
    }

    private var fallbackRouteCoordinates: [CLLocationCoordinate2D] {
        let sortedReadings = routeReadings
            .filter { activeRouteSpan.contains($0.timestamp) }
            .sorted { $0.timestamp < $1.timestamp }
            .compactMap(\.point)
            .filter(isValidCoordinate)
        return sortedReadings.reduce(into: []) { result, point in
            let coordinate = CLLocationCoordinate2D(
                latitude: point.latitude,
                longitude: point.longitude
            )
            guard let previous = result.last else {
                result.append(coordinate)
                return
            }
            if CLLocation(latitude: previous.latitude, longitude: previous.longitude)
                .distance(from: CLLocation(
                    latitude: coordinate.latitude,
                    longitude: coordinate.longitude
                )) >= 8 {
                result.append(coordinate)
            }
        }
    }

    private var displayedRouteCoordinates: [CLLocationCoordinate2D] {
        let segmentCoordinates = routeSegments.flatMap(coordinates(for:))
        if segmentCoordinates.count >= 2 {
            return segmentCoordinates
        }
        guard allowsFallbackRoutePath else { return [] }
        return fallbackRouteCoordinates
    }

    private func routeModeName(_ mode: TravelMode) -> String {
        switch mode {
        case .walking:
            "걷기"
        case .running:
            "달리기"
        case .cycling:
            "자전거"
        case .bus:
            "버스"
        case .subway:
            "지하철"
        case .taxi:
            "택시"
        case .car:
            "자가용"
        case .train:
            "기차"
        case .airplane:
            "비행기"
        case .ship:
            "배"
        }
    }

    private func routeModeSystemImage(_ mode: TravelMode) -> String {
        switch mode {
        case .walking: "figure.walk"
        case .running: "figure.run"
        case .cycling: "bicycle"
        case .bus: "bus"
        case .subway: "tram"
        case .taxi: "car.side"
        case .car: "car"
        case .train: "train.side.front.car"
        case .airplane: "airplane"
        case .ship: "ferry"
        }
    }

    private func travelModeEditor(for travel: TravelSegment) -> some View {
        HStack(spacing: 8) {
            Label(
                routeModeName(travel.mode),
                systemImage: routeModeSystemImage(travel.mode)
            )
            .font(.taption(size: 9, weight: .bold))
            .foregroundStyle(Color.tpInk)

            Text(
                "\(travel.span.start.formatted(date: .omitted, time: .shortened))–\(travel.span.end.formatted(date: .omitted, time: .shortened))"
            )
            .font(.taption(size: 8))
            .foregroundStyle(Color.tpSecondary)

            Spacer(minLength: 4)

            Menu {
                ForEach(TravelMode.allCases, id: \.self) { mode in
                    Button {
                        model.confirmTravel(travel.id, mode: mode)
                    } label: {
                        Label(
                            routeModeName(mode),
                            systemImage: routeModeSystemImage(mode)
                        )
                    }
                }
            } label: {
                Label("이동수단 변경", systemImage: "pencil")
                    .font(.taption(size: 8.5, weight: .bold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(Color.tpInk, in: Capsule())
            }
            .accessibilityLabel("이동수단 변경")
            .accessibilityValue(routeModeName(travel.mode))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .stroke(Color.tpLine, lineWidth: 0.7)
        }
    }

    private func isValidCoordinate(_ point: GeoPoint) -> Bool {
        guard point.latitude.isFinite, point.longitude.isFinite else { return false }
        return point.latitude >= -90 && point.latitude <= 90 &&
            point.longitude >= -180 && point.longitude <= 180 &&
            !(point.latitude == 0 && point.longitude == 0)
    }

    private func routeCoordinates(
        for segment: TravelSegment,
        includeImprecise: Bool
    ) -> [CLLocationCoordinate2D] {
        var points: [GeoPoint] = []
        if let from = segment.fromPlaceID,
           let point = model.snapshot.places.first(where: { $0.id == from })?.point,
           isValidCoordinate(point) {
            points.append(point)
        }
        let readings = routeReadings
            .filter { segment.span.contains($0.timestamp) }
            .sorted { $0.timestamp < $1.timestamp }
            .compactMap(\.point)
            .filter(isValidCoordinate)
        let preferredReadings = includeImprecise
            ? readings
            : readings.filter { $0.horizontalAccuracy <= 200 }

        if preferredReadings.count >= 2 || includeImprecise {
            points.append(contentsOf: preferredReadings)
        } else if let first = readings.first {
            points.append(first)
        }

        if let to = segment.toPlaceID,
           let point = model.snapshot.places.first(where: { $0.id == to })?.point,
           isValidCoordinate(point) {
            points.append(point)
        }

        return points.reduce(into: []) { result, point in
            guard let previous = result.last else {
                result.append(CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude))
                return
            }
            let coordinate = CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
            if CLLocation(latitude: previous.latitude, longitude: previous.longitude)
                .distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)) >= 8 {
                result.append(coordinate)
            }
        }
    }

    private func coordinates(for segment: TravelSegment) -> [CLLocationCoordinate2D] {
        var values = routeCoordinates(for: segment, includeImprecise: false)
        if values.isEmpty || values.count == 1 {
            let fallback = routeCoordinates(for: segment, includeImprecise: true)
            if fallback.count >= 2 {
                return fallback
            }
            if fallback.count == 1 {
                values = fallback
            }
        }
        if values.count == 1 {
            let only = values[0]
            return [
                only,
                CLLocationCoordinate2D(
                    latitude: only.latitude + 0.00002,
                    longitude: only.longitude + 0.00002
                ),
            ]
        }
        return values
    }

    private func routeColor(for mode: TravelMode) -> Color {
        switch mode {
        case .walking, .running: .tpHealthDark
        case .cycling: .tpTransitDark
        case .bus, .subway, .train: .tpProjectDark
        case .taxi, .car: .tpInk
        case .airplane, .ship: .tpPlaceDark
        }
    }

    private func fitMapToRoutes() {
        if let focus = playheadFocusCoordinate {
            if let lastMapFocusCoordinate,
               CLLocation(
                   latitude: lastMapFocusCoordinate.latitude,
                   longitude: lastMapFocusCoordinate.longitude
               ).distance(
                   from: CLLocation(
                       latitude: focus.latitude,
                       longitude: focus.longitude
                   )
               ) < 5 {
                return
            }
            lastMapFocusCoordinate = focus
            mapPosition = .region(
                MKCoordinateRegion(
                    center: focus,
                    span: MKCoordinateSpan(
                        latitudeDelta: 0.004,
                        longitudeDelta: 0.004
                    )
                )
            )
            return
        }

        lastMapFocusCoordinate = nil

        let values = displayedRouteCoordinates
        guard !values.isEmpty else {
            mapPosition = .automatic
            return
        }
        let latitudes = values.map(\.latitude)
        let longitudes = values.map(\.longitude)
        mapPosition = .region(
            MKCoordinateRegion(
                center: CLLocationCoordinate2D(
                    latitude: (latitudes.min()! + latitudes.max()!) / 2,
                    longitude: (longitudes.min()! + longitudes.max()!) / 2
                ),
                span: MKCoordinateSpan(
                    latitudeDelta: max(0.005, (latitudes.max()! - latitudes.min()!) * 1.45),
                    longitudeDelta: max(0.005, (longitudes.max()! - longitudes.min()!) * 1.45)
                )
            )
        )
    }
}

struct GroupGanttView: View {
    @Bindable var model: AppModel
    @State private var dayZoom: TimelineZoomPreset = .oneDay
    @State private var selectedTimelineItem: TimelineSelection?
    @State private var detailSection: TimelineDetailSection = .map
    @State private var selectedPhotoCluster: PhotoCluster?
    @State private var routeReadings: [SensorReading] = []
    @State private var editingPlanID: UUID?
    @State private var mapPlayheadDate: Date?
    @State private var playheadDetailGate = TimelinePlayheadDetailGate()

    var body: some View {
        VStack(spacing: 0) {
            DraftTopBar(
                title: selectedGroup?.title ?? "신제품 기획",
                trailing: selectedGroup.map(periodText) ?? "7.27 – 8.2",
                selectedScale: model.selectedScale,
                onScaleChange: { model.selectScale($0) },
                dayZoom: dayZoom,
                onDayZoomChange: { dayZoom = $0 },
                onBack: { model.closeCurrentGroup() }
            )
            .simultaneousGesture(
                TapGesture().onEnded {
                    editingPlanID = nil
                }
            )
            TimelineBoard(
                model: model,
                scale: model.selectedScale,
                storedPlans: model.snapshot.plans,
                isGroup: true,
                dayZoom: $dayZoom,
                editingPlanID: $editingPlanID,
                onPlayheadMove: { date in
                    requestPlayheadDetailUpdate(at: date)
                },
                onSelection: { selection in
                    playheadDetailGate.cancel()
                    mapPlayheadDate = nil
                    selectedTimelineItem = selection
                    selectedPhotoCluster = nil
                    detailSection = selection.preferredDetailSection
                },
                onFocus: { selection in
                    playheadDetailGate.cancel()
                    mapPlayheadDate = nil
                    selectedTimelineItem = selection
                    selectedPhotoCluster = nil
                    detailSection = selection.preferredDetailSection
                },
                onPhotoSelection: { cluster in
                    playheadDetailGate.cancel()
                    editingPlanID = nil
                    mapPlayheadDate = nil
                    selectedPhotoCluster = cluster
                    selectedTimelineItem = TimelineSelection(
                        title: "사진",
                        span: cluster.detailSpan,
                        planID: nil,
                        isRoute: false,
                        categoryID: "photo",
                        categoryName: "사진"
                    )
                    detailSection = .photo
                }
            )
            Spacer(minLength: 0)
                .contentShape(Rectangle())
                .onTapGesture {
                    editingPlanID = nil
                }
            TimelineDetailPanel(
                model: model,
                selection: selectedTimelineItem,
                playheadDate: mapPlayheadDate,
                section: $detailSection,
                highlightedSection: selectedTimelineItem?.preferredDetailSection,
                selectedPhotoCluster: $selectedPhotoCluster,
                routeReadings: routeReadings,
                onActualDeleted: { actualID in
                    if selectedTimelineItem?.actualID == actualID {
                        selectedTimelineItem = nil
                    }
                }
            )
            .simultaneousGesture(
                TapGesture().onEnded {
                    editingPlanID = nil
                }
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.white)
        .task(id: routeReadingsSpan) {
            routeReadings = await model.sensorReadings(in: routeReadingsSpan)
        }
        .onDisappear {
            playheadDetailGate.cancel()
        }
    }

    private func requestPlayheadDetailUpdate(at date: Date) {
        playheadDetailGate.submit(date) { deliveredDate in
            mapPlayheadDate = deliveredDate
            focusMapOnPlayhead(at: deliveredDate)
        }
    }

    private func focusMapOnPlayhead(at date: Date) {
        guard let selection = timelineSelection(at: date) else {
            selectedPhotoCluster = nil
            selectedTimelineItem = TimelineSelection(
                title: "현재 위치",
                span: playheadFocusSpan(around: date),
                planID: nil,
                isRoute: true,
                categoryID: "movement",
                categoryName: "이동"
            )
            return
        }

        selectedTimelineItem = selection
        if selection.categoryID != "photo" {
            selectedPhotoCluster = nil
        }
    }

    private func timelineSelection(at date: Date) -> TimelineSelection? {
        if let cluster = photoCluster(at: date) {
            selectedPhotoCluster = cluster
            return TimelineSelection(
                title: "사진",
                span: cluster.detailSpan,
                planID: nil,
                isRoute: false,
                categoryID: "photo",
                categoryName: "사진"
            )
        }

        if let travel = model.snapshot.travel.first(where: {
            $0.span.contains(date)
        }) {
            return TimelineSelection(
                title: timelineTravelModeName(travel.mode),
                span: travel.span,
                planID: nil,
                travelID: travel.id,
                isRoute: true,
                categoryID: "movement",
                categoryName: "이동"
            )
        }

        if let event = model.snapshot.plans.first(where: {
            $0.span.contains(date)
                && $0.categoryID == "event"
                && $0.parentID == nil
        }) {
            return TimelineSelection(
                title: event.title,
                span: event.span,
                planID: event.id,
                isRoute: false,
                categoryID: "event",
                categoryName: "이벤트"
            )
        }

        if let calendarEvent = model.snapshot.calendarEvents.first(where: {
            $0.span.contains(date)
        }) {
            return TimelineSelection(
                title: calendarEvent.title,
                span: calendarEvent.span,
                planID: nil,
                isRoute: false,
                categoryID: "calendar",
                categoryName: "일정"
            )
        }

        if let plan = model.snapshot.plans.first(where: {
            $0.span.contains(date)
                && $0.categoryID != "event"
                && $0.parentID == nil
        }) {
            return TimelineSelection(
                title: plan.title,
                span: plan.span,
                planID: plan.id,
                isRoute: false,
                categoryID: plan.categoryID,
                categoryName: categoryName(for: plan.categoryID)
            )
        }

        return nil
    }

    private func categoryName(for categoryID: String) -> String? {
        model.snapshot.categories.first { $0.id == categoryID }?.name
    }

    private func photoCluster(at date: Date) -> PhotoCluster? {
        PhotoClusterer.nearestCluster(
            to: date,
            in: model.snapshot.photos,
            tolerance: photoPlayheadTolerance
        )
    }

    private var photoPlayheadTolerance: TimeInterval {
        guard model.selectedScale == .day else {
            return 24 * 60 * 60
        }
        return min(
            25 * 60,
            max(60, dayZoom.duration * 0.035)
        )
    }

    private var selectedGroup: PlanRecord? {
        guard let id = model.selectedGroupPlanID else { return nil }
        return model.snapshot.plans.first { $0.id == id }
    }

    private func periodText(_ plan: PlanRecord) -> String {
        "\(plan.span.start.formatted(.dateTime.month().day())) – \(plan.span.end.formatted(.dateTime.month().day()))"
    }

    private var selectedDaySpan: TimeSpan {
        TimelineAggregationEngine().interval(
            for: .day,
            containing: model.selectedDate
        )
    }

    private var routeReadingsSpan: TimeSpan {
        if mapPlayheadDate != nil {
            return selectedDaySpan
        }
        return selectedTimelineItem?.span ?? selectedDaySpan
    }
}

private struct TimelineBoardLayoutSnapshot {
    var rows: [TimelineRowModel]
    var axisMarkers: [TimelineAxisMarker]
    var photoClusters: [PhotoCluster]
    var summaryBuckets: [SummaryBucket]
    var summaryColors: [SummaryColor]
    var hasVisibleActuals: Bool
    var visibleActualDuration: TimeInterval
    var visiblePlannedDuration: TimeInterval
    var contentHeight: CGFloat
}

private struct TimelineBoardLayoutKey: Equatable {
    let snapshotRevision: UInt64
    let scale: TimeScale
    let isGroup: Bool
    let selectedGroupPlanID: UUID?
    let spanStart: TimeInterval
    let spanEnd: TimeInterval
    let viewportStart: Double
    let viewportEnd: Double
}

@MainActor
private final class TimelineBoardLayoutCache {
    private var key: TimelineBoardLayoutKey?
    private var snapshot: TimelineBoardLayoutSnapshot?

    func value(
        for key: TimelineBoardLayoutKey,
        build: () -> TimelineBoardLayoutSnapshot
    ) -> TimelineBoardLayoutSnapshot {
        if self.key == key, let snapshot {
            return snapshot
        }
        let snapshot = build()
        self.key = key
        self.snapshot = snapshot
        return snapshot
    }
}

private struct TimelineBoardDataIndex {
    let childCounts: [UUID: Int]
    let parentPlanIDs: Set<UUID>
    let categoryNames: [String: String]

    init(
        plans: [PlanRecord],
        categories: [CategoryDefinition]
    ) {
        let parentIDs = plans.compactMap(\.parentID)
        childCounts = Dictionary(
            parentIDs.map { ($0, 1) },
            uniquingKeysWith: +
        )
        parentPlanIDs = Set(parentIDs)
        categoryNames = Dictionary(
            categories.map { ($0.id, $0.name) },
            uniquingKeysWith: { first, _ in first }
        )
    }
}

private struct PlanCategoryPathKey: Hashable {
    let categoryID: String
    let middleName: String?
    let subName: String?

    var isRoot: Bool {
        middleName == nil && subName == nil
    }

    var stableID: String {
        [
            categoryID,
            middleName ?? "_",
            subName ?? "_",
        ].joined(separator: "::")
    }
}

private struct TimelineBoard: View {
    @Bindable var model: AppModel
    let scale: TimeScale
    let storedPlans: [PlanRecord]
    var isGroup = false
    @Binding var dayZoom: TimelineZoomPreset
    @Binding var editingPlanID: UUID?
    var onPlayheadMove: ((Date) -> Void)?
    var onSelection: ((TimelineSelection) -> Void)?
    var onFocus: ((TimelineSelection) -> Void)?
    var onPhotoSelection: ((PhotoCluster) -> Void)?
    @State private var viewport = GanttViewport.full
    @State private var dragOrigin: GanttViewport?
    @State private var magnifyOrigin: GanttViewport?
    @State private var continuousCenterDate: Date = .now
    @State private var continuousDragOrigin: Date?
    @State private var continuousZoomDurationOrigin: TimeInterval?
    @State private var zoomFeedbackSequence = 0
    @State private var selectedRowID: String?
    @State private var layoutCache = TimelineBoardLayoutCache()
    @State private var lastContinuousRenderUptime: TimeInterval = 0
    private let axisHeight: CGFloat = 32

    var body: some View {
        let layout = cachedLayoutSnapshot()
        GeometryReader { boardProxy in
            VStack(spacing: 0) {
                axis(markers: layout.axisMarkers)
                    .simultaneousGesture(
                        TapGesture().onEnded {
                            editingPlanID = nil
                        }
                    )

                ScrollView(.vertical, showsIndicators: false) {
                    GeometryReader { _ in
                        ZStack(alignment: .topLeading) {
                            Color.clear
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    editingPlanID = nil
                                }

                            VStack(spacing: 0) {
                                ForEach(layout.rows) { row in
                                    TimelineRow(
                                        row: row,
                                        isSelected: selectedRowID == row.id,
                                        editingPlanID: editingPlanID,
                                        visibleDuration:
                                            visibleSpan.duration * viewport.length,
                                        viewport: viewport,
                                        onBlockTap: handleTap,
                                        onBlockDoubleTap: focusOnBlock,
                                        onEdit: { editingPlanID = $0 },
                                        onMove: { block, delta in
                                            guard let planID = block.planID else {
                                                return
                                            }
                                            model.movePlan(planID, by: delta)
                                        },
                                        onResizeStart: { block, delta in
                                            guard let planID = block.planID else {
                                                return
                                            }
                                            model.resizePlan(
                                                planID,
                                                startDelta: delta
                                            )
                                        },
                                        onResizeEnd: { block, delta in
                                            guard let planID = block.planID else {
                                                return
                                            }
                                            model.resizePlan(
                                                planID,
                                                endDelta: delta
                                            )
                                        },
                                        onRowTap: { handleRowTap(row) }
                                    )
                                }

                                if scale == .day,
                                   !isGroup,
                                   !layout.photoClusters.isEmpty {
                                    photoRow(layout.photoClusters)
                                } else if scale != .day {
                                    summaryStrip(
                                        buckets: layout.summaryBuckets,
                                        colors: layout.summaryColors
                                    )
                                }

                                if scale == .day, layout.hasVisibleActuals {
                                    planActualStrip(
                                        plannedDuration:
                                            layout.visiblePlannedDuration,
                                        actualDuration:
                                            layout.visibleActualDuration
                                    )
                                }
                            }

                            gridLines(markers: layout.axisMarkers)
                                .allowsHitTesting(false)

                            TimelineView(.periodic(from: .now, by: 60)) { context in
                                currentLine(at: context.date)
                                    .allowsHitTesting(false)
                            }
                        }
                        .contentShape(Rectangle())
                        .frame(maxHeight: .infinity, alignment: .top)
                    }
                    .frame(height: layout.contentHeight)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .contentShape(Rectangle())
            .simultaneousGesture(
                viewportDragGesture(
                    width: max(
                        1,
                        boardProxy.size.width - scheduleLabelColumnWidth
                    )
                )
            )
            .simultaneousGesture(viewportMagnifyGesture)
            .background {
                TwoFingerDoubleTapAttachment {
                    resetViewport(withFeedback: true)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background(Color.white)
        .onAppear {
            continuousCenterDate = model.selectedDate
            if isContinuousDay {
                onPlayheadMove?(continuousCenterDate)
            }
        }
        .onChange(of: scale) { _, _ in
            if isContinuousDay {
                continuousCenterDate = model.selectedDate
                onPlayheadMove?(continuousCenterDate)
            }
            resetViewport()
        }
        .onChange(of: model.selectedDate) { _, newDate in
            if isContinuousDay {
                continuousCenterDate = newDate
                onPlayheadMove?(newDate)
            } else {
                resetViewport()
            }
        }
        .accessibilityHint(
            "간트 본문을 드래그해 이동하고 두 손가락으로 최대 1분 단위까지 확대합니다"
        )
        .accessibilityIdentifier("schedule.timeline.board")
        .accessibilityValue(currentZoomStage.label)
        .sensoryFeedback(
            .impact(weight: .light),
            trigger: zoomFeedbackSequence
        )
    }

    private func cachedLayoutSnapshot() -> TimelineBoardLayoutSnapshot {
        let span = visibleSpan
        let key = TimelineBoardLayoutKey(
            snapshotRevision: model.snapshotRevision,
            scale: scale,
            isGroup: isGroup,
            selectedGroupPlanID: model.selectedGroupPlanID,
            spanStart: span.start.timeIntervalSinceReferenceDate,
            spanEnd: span.end.timeIntervalSinceReferenceDate,
            viewportStart: viewport.start,
            viewportEnd: viewport.end
        )
        return layoutCache.value(for: key) {
            makeLayoutSnapshot(in: span)
        }
    }

    private func makeLayoutSnapshot(
        in span: TimeSpan
    ) -> TimelineBoardLayoutSnapshot {
        let index = TimelineBoardDataIndex(
            plans: storedPlans,
            categories: model.snapshot.categories
        )
        let rowModels = rows(in: span, index: index)
        let clusters = photoClusters(in: span)
        let buckets = summaryBuckets(in: span)
        let colors = summaryColors(for: buckets)
        let hasActuals = model.snapshot.actuals.contains {
            $0.span().intersection(with: span) != nil
        }
        let actualDuration = visibleActualDuration(in: span)
        let plannedDuration = visiblePlannedDuration(
            in: span,
            parentPlanIDs: index.parentPlanIDs
        )
        let footerHeight: CGFloat
        if scale == .day {
            footerHeight = !isGroup && !clusters.isEmpty ? 65 : 0
        } else {
            footerHeight = 46
        }
        let planActualHeight: CGFloat =
            scale == .day && hasActuals ? 30 : 0
        return TimelineBoardLayoutSnapshot(
            rows: rowModels,
            axisMarkers: axisMarkers(in: span),
            photoClusters: clusters,
            summaryBuckets: buckets,
            summaryColors: colors,
            hasVisibleActuals: hasActuals,
            visibleActualDuration: actualDuration,
            visiblePlannedDuration: plannedDuration,
            contentHeight: rowModels.reduce(0) { $0 + $1.height }
                + footerHeight
                + planActualHeight
        )
    }

    private func axis(markers: [TimelineAxisMarker]) -> some View {
        HStack(spacing: 0) {
            if isContinuousDay {
                Text(dayZoom.rawValue)
                    .font(.taption(size: 8.5, weight: .bold))
                    .foregroundStyle(Color.tpSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                .accessibilityLabel("일 타임라인 배율 \(dayZoom.rawValue), 위 상단 메뉴에서 변경")
                .frame(width: scheduleLabelColumnWidth)
            } else {
                Button {
                    resetViewport(withFeedback: true)
                } label: {
                    HStack(spacing: 3) {
                        Text(currentZoomStage.label)
                        if !viewport.isFull {
                            Image(systemName: "arrow.counterclockwise")
                        }
                    }
                    .font(.taption(size: 8.5, weight: .bold))
                    .foregroundStyle(
                        viewport.isFull
                            ? Color.tpSecondary
                            : Color.tpInk
                    )
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(
                        viewport.isFull
                            ? Color.clear
                            : Color(red: 0.94, green: 0.94, blue: 0.95),
                        in: Capsule()
                    )
                }
                .buttonStyle(.plain)
                .frame(width: scheduleLabelColumnWidth)
                .accessibilityLabel(
                    viewport.isFull
                        ? "현재 배율 \(currentZoomStage.label)"
                        : "현재 배율 \(currentZoomStage.label), 전체 보기로 복귀"
                )
                .accessibilityIdentifier("schedule.zoom.level")
            }
            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    ForEach(markers) { marker in
                        VStack(spacing: 0) {
                            Text(marker.label)
                            if let holidayName = marker.holidayName {
                                Text(holidayName)
                                    .font(.taption(size: 7, weight: .semibold))
                                    .foregroundStyle(Color.tpNow)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.55)
                            }
                        }
                        .accessibilityLabel(
                            marker.holidayName.map {
                                "\(marker.label), \($0)"
                            } ?? marker.label
                        )
                            .font(
                                .taption(
                                    size: 10,
                                    weight: marker.isCurrent
                                        ? .bold
                                        : .regular
                                )
                            )
                            .foregroundStyle(
                                marker.isCurrent
                                    ? Color.tpNow
                                    : Color.tpSecondary
                            )
                            .fixedSize()
                            .position(
                                x: markerX(
                                    marker,
                                    width: proxy.size.width
                                ),
                                y: proxy.size.height / 2
                            )
                    }
                }
            }
            .clipped()
        }
        .padding(.leading, 4)
        .padding(.trailing, 4)
        .frame(height: axisHeight)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.tpLine).frame(height: 0.5)
        }
        .contentShape(Rectangle())
    }

    private func rows(
        in span: TimeSpan,
        index: TimelineBoardDataIndex
    ) -> [TimelineRowModel] {
        let resolved = resolvedRows(in: span, index: index)
        if (scale == .day && !isGroup && !resolved.isEmpty)
            || resolved.contains(where: { !$0.blocks.isEmpty }) {
            return resolved
        }

        if isGroup {
            return groupRows
        }

        switch scale {
        case .day:
            let dayRows: [TimelineRowModel] = [
                .init(
                    title: "캘린더",
                    dotColor: Color(red: 0.56, green: 0.56, blue: 0.58),
                    blocks: [
                        .init(
                            title: "병원 14:00",
                            start: 0.47,
                            length: 0.22,
                            isFixed: true
                        )
                    ]
                ),
                .init(
                    title: "프로젝트",
                    category: .project,
                    blocks: [.init(title: "보고서 작성", start: 0.14, length: 0.44)]
                ),
                .init(
                    title: "운동",
                    category: .exercise,
                    blocks: [.init(title: "러닝 40분", start: 0.63, length: 0.20)]
                ),
                .init(
                    title: "학습",
                    category: .study,
                    blocks: [.init(title: "영어", start: 0.80, length: 0.17)]
                ),
                .init(
                    title: "생활",
                    category: .routine,
                    blocks: [.init(title: "점심", start: 0.38, length: 0.12)]
                ),
            ]

            return resolved + dayRows

        case .week:
            return [
                .init(
                    title: "프로젝트",
                    category: .project,
                    height: 68,
                    blocks: [
                        .init(title: "신제품 기획", start: 0.02, length: 0.55, top: 8, groupCount: 4),
                        .init(title: "보고서", start: 0.44, length: 0.26, top: 38),
                    ]
                ),
                .init(
                    title: "운동",
                    category: .exercise,
                    blocks: [
                        .init(title: "런", start: 0.02, length: 0.12),
                        .init(title: "런", start: 0.30, length: 0.12),
                        .init(title: "런", start: 0.58, length: 0.12),
                        .init(title: "런", start: 0.86, length: 0.12),
                    ]
                ),
                .init(
                    title: "학습",
                    category: .study,
                    blocks: [.init(title: "영어 매일 30분", start: 0.02, length: 0.83)]
                ),
            ]

        case .month:
            return [
                .init(
                    title: "프로젝트",
                    category: .project,
                    height: 68,
                    blocks: [
                        .init(title: "신제품 기획", start: 0.08, length: 0.44, top: 8, groupCount: 4),
                        .init(title: "월간 보고서", start: 0.62, length: 0.27, top: 38),
                    ]
                ),
                .init(
                    title: "운동",
                    category: .exercise,
                    blocks: [.init(title: "주 3회 운동", start: 0.02, length: 0.96)]
                ),
                .init(
                    title: "학습",
                    category: .study,
                    blocks: [.init(title: "자격증 2단계", start: 0.16, length: 0.56)]
                ),
                .init(
                    title: "여행",
                    category: .travel,
                    blocks: [.init(title: "출발", start: 0.76, length: 0.20, top: 20, height: 20)]
                ),
            ]

        case .year:
            return [
                .init(
                    title: "학습",
                    category: .study,
                    blocks: [.init(title: "자격증 취득", start: 0.16, length: 0.34, groupCount: 3)]
                ),
                .init(
                    title: "여행",
                    category: .travel,
                    blocks: [
                        .init(title: "일본", start: 0.58, length: 0.10),
                        .init(title: "제주", start: 0.88, length: 0.10, top: 20, height: 20),
                    ]
                ),
                .init(
                    title: "운동",
                    category: .exercise,
                    blocks: [.init(title: "주 3회 운동 습관", start: 0.02, length: 0.96)]
                ),
                .init(
                    title: "프로젝트",
                    category: .project,
                    blocks: [.init(title: "신제품 프로젝트", start: 0.25, length: 0.42, groupCount: 4)]
                ),
            ]
        }
    }

    private func resolvedRows(
        in span: TimeSpan,
        index: TimelineBoardDataIndex
    ) -> [TimelineRowModel] {
        if isGroup {
            guard let groupID = model.selectedGroupPlanID else { return [] }
            return rows(
                from: PlanHierarchy.children(of: groupID, in: storedPlans),
                includesCalendar: false,
                visibleSpan: span,
                index: index
            )
        }
        return rows(
            from: storedPlans.filter { $0.parentID == nil },
            includesCalendar: true,
            visibleSpan: span,
            index: index
        )
    }

    private func rows(
        from plans: [PlanRecord],
        includesCalendar: Bool,
        visibleSpan span: TimeSpan,
        index: TimelineBoardDataIndex
    ) -> [TimelineRowModel] {
        let visiblePlans = plans
            .filter { $0.span.intersection(with: span) != nil }
            .sorted { $0.span.start < $1.span.start }
        let grouped = Dictionary(grouping: visiblePlans, by: \.categoryID)
        let visibleActuals = model.snapshot.actuals
            .filter { $0.span().intersection(with: span) != nil }
            .sorted { $0.startedAt < $1.startedAt }
        let usesAutomaticDayRows = scale == .day && includesCalendar
        let automaticActuals = AutomaticRecordTimelineEngine.activities(
            from: visibleActuals,
            inside: span
        )
        let categoryVisibleActuals = usesAutomaticDayRows
            ? visibleActuals.filter {
                $0.source != .healthKit && $0.source != .appleWatch
            }
            : visibleActuals
        let actualsGrouped = Dictionary(
            grouping: categoryVisibleActuals,
            by: \.categoryID
        )
        var values: [TimelineRowModel] = []

        let events = model.snapshot.calendarEvents
            .filter { $0.span.intersection(with: span) != nil }
            .sorted { $0.span.start < $1.span.start }
        if usesAutomaticDayRows {
            values.append(
                contentsOf: automaticDayRows(
                    events: events,
                    plansByCategory: grouped,
                    actuals: automaticActuals,
                    visibleSpan: span,
                    index: index
                )
            )
        } else if includesCalendar {
            if !events.isEmpty {
                let allocation = laneAllocation(events, span: \.span)
                values.append(
                    TimelineRowModel(
                        title: "일정",
                        dotColor: Color(red: 0.56, green: 0.56, blue: 0.58),
                        isSystemAutomatic: true,
                        height: max(
                            60,
                            14 + CGFloat(allocation.count) * 28
                        ),
                        blocks: events.map { event in
                            timelineBlock(
                                title: event.title,
                                span: event.span,
                                top: 7 + CGFloat(
                                    allocation.lanes[event.id, default: 0]
                                ) * 28,
                                height: 22,
                                isFixed: true,
                                detailText: calendarDetailText(event)
                            )
                        }
                    )
                )
            }
        }

        let orderedCategories = model.snapshot.categories.sorted {
            $0.sortOrder < $1.sortOrder
        }
        for definition in orderedCategories {
            if usesAutomaticDayRows,
               definition.id == "movement" || definition.id == "location" {
                continue
            }
            guard !definition.isHidden else {
                continue
            }
            let categoryPlans = grouped[definition.id, default: []]
            let categoryActuals = actualsGrouped[definition.id, default: []]
            guard !categoryPlans.isEmpty
                || !categoryActuals.isEmpty else {
                continue
            }
            let category = PlanCategory(categoryID: definition.id)
            let plansByPath = Dictionary(
                grouping: categoryPlans,
                by: planCategoryPath
            )
            let rootKey = PlanCategoryPathKey(
                categoryID: definition.id,
                middleName: nil,
                subName: nil
            )
            let rowKeys = Array(
                Set(plansByPath.keys)
                    .union(categoryActuals.isEmpty ? [] : [rootKey])
            )
            .sorted {
                compareCategoryPath(
                    $0,
                    $1,
                    categoryName: definition.name
                )
            }

            for key in rowKeys {
                let rowPlans = plansByPath[key, default: []]
                let rowActuals = key.isRoot ? categoryActuals : []
                let planAllocation = laneAllocation(
                    rowPlans,
                    span: \.span
                )
                let actualAllocation = laneAllocation(
                    rowActuals,
                    span: { $0.span() }
                )
                let planBlocks = rowPlans.map { plan in
                    timelineBlock(
                        plan: plan,
                        index: index,
                        top: 7 + CGFloat(
                            planAllocation.lanes[plan.id, default: 0]
                        ) * 28,
                        height: 22
                    )
                }
                let actualBlocks = rowActuals.map { actual in
                    timelineBlock(
                        actual: actual,
                        index: index,
                        top: 7
                            + CGFloat(planAllocation.count) * 28
                            + CGFloat(
                                actualAllocation.lanes[actual.id, default: 0]
                            ) * 16,
                        height: 12
                    )
                }
                let sensorBlocks = key.isRoot
                    ? sensorTimelineBlocks(
                        categoryID: definition.id,
                        top: 7
                            + CGFloat(planAllocation.count) * 28
                            + CGFloat(actualAllocation.count) * 16,
                        visibleSpan: span
                    )
                    : []
                let sensorLaneCount = sensorBlocks.isEmpty ? 0 : 1
                values.append(
                    TimelineRowModel(
                        title: categoryPathTitle(
                            categoryName: definition.name,
                            key: key
                        ),
                        id: key.stableID,
                        category: category,
                        categoryID: definition.id,
                        dotColor: Color(hex: definition.darkHex),
                        fillColor: Color(hex: definition.lightHex),
                        actualColor: Color(hex: definition.actualHex),
                        height: max(
                            key.isRoot ? 52 : 64,
                            14
                                + CGFloat(planAllocation.count) * 28
                                + CGFloat(actualAllocation.count) * 16
                                + CGFloat(sensorLaneCount) * 22
                        ),
                        blocks: planBlocks + actualBlocks + sensorBlocks
                    )
                )
            }
        }

        let knownIDs = Set(orderedCategories.map(\.id))
        let unknownIDs = Set(grouped.keys)
            .union(actualsGrouped.keys)
            .subtracting(knownIDs)
        for categoryID in unknownIDs.sorted() {
            let categoryPlans = grouped[categoryID, default: []]
            let categoryActuals = actualsGrouped[categoryID, default: []]
            let planAllocation = laneAllocation(
                categoryPlans,
                span: \.span
            )
            let actualAllocation = laneAllocation(
                categoryActuals,
                span: { $0.span() }
            )
            values.append(
                TimelineRowModel(
                    title: categoryID,
                    category: PlanCategory(categoryID: categoryID),
                    categoryID: categoryID,
                    height: max(
                        60,
                        14
                            + CGFloat(planAllocation.count) * 28
                            + CGFloat(actualAllocation.count) * 16
                    ),
                    blocks: categoryPlans.map { plan in
                        timelineBlock(
                            plan: plan,
                            index: index,
                            top: 7 + CGFloat(
                                planAllocation.lanes[plan.id, default: 0]
                            ) * 28,
                            height: 22
                        )
                    } + categoryActuals.map { actual in
                        timelineBlock(
                            actual: actual,
                            index: index,
                            top: 7
                                + CGFloat(planAllocation.count) * 28
                                + CGFloat(
                                    actualAllocation.lanes[
                                        actual.id,
                                        default: 0
                                    ]
                                ) * 16,
                            height: 12
                        )
                    }
                )
            )
        }
        return values
    }

    private func planCategoryPath(
        for plan: PlanRecord
    ) -> PlanCategoryPathKey {
        PlanCategoryPathKey(
            categoryID: plan.categoryID,
            middleName: normalizedCategoryPart(plan.middleCategoryName),
            subName: normalizedCategoryPart(plan.subCategoryName)
        )
    }

    private func normalizedCategoryPart(_ value: String?) -> String? {
        let clean = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean?.isEmpty == false ? clean : nil
    }

    private func categoryPathParts(
        categoryName: String,
        key: PlanCategoryPathKey
    ) -> [String] {
        [categoryName, key.middleName, key.subName].compactMap { $0 }
    }

    private func categoryPathTitle(
        categoryName: String,
        key: PlanCategoryPathKey
    ) -> String {
        categoryPathParts(categoryName: categoryName, key: key)
            .joined(separator: "\n")
    }

    private func categoryPathDetail(
        categoryName: String,
        key: PlanCategoryPathKey
    ) -> String {
        categoryPathParts(categoryName: categoryName, key: key)
            .joined(separator: " › ")
    }

    private func compareCategoryPath(
        _ lhs: PlanCategoryPathKey,
        _ rhs: PlanCategoryPathKey,
        categoryName: String
    ) -> Bool {
        if lhs.isRoot != rhs.isRoot {
            return lhs.isRoot
        }
        return categoryPathDetail(categoryName: categoryName, key: lhs)
            < categoryPathDetail(categoryName: categoryName, key: rhs)
    }

    private func automaticDayRows(
        events: [CalendarRecord],
        plansByCategory: [String: [PlanRecord]],
        actuals: [ActualRecord],
        visibleSpan: TimeSpan,
        index: TimelineBoardDataIndex
    ) -> [TimelineRowModel] {
        [
            automaticScheduleRow(events),
            automaticLocationRow(
                plans: plansByCategory["location", default: []],
                visibleSpan: visibleSpan,
                index: index
            ),
            automaticMovementRow(
                plans: plansByCategory["movement", default: []],
                visibleSpan: visibleSpan,
                index: index
            ),
            automaticActivityRow(actuals),
        ]
    }

    private func automaticScheduleRow(
        _ events: [CalendarRecord]
    ) -> TimelineRowModel {
        let allocation = laneAllocation(events, span: \.span)
        return TimelineRowModel(
            title: "일정",
            id: "calendar",
            categoryID: "calendar",
            dotColor: Color(red: 0.56, green: 0.56, blue: 0.58),
            isSystemAutomatic: true,
            height: compactAutomaticHeight(allocation.count),
            blocks: events.map { event in
                timelineBlock(
                    title: event.title,
                    span: event.span,
                    top: compactAutomaticTop(
                        allocation.lanes[event.id, default: 0]
                    ),
                    height: 14,
                    isFixed: true,
                    detailText: calendarDetailText(event)
                )
            }
        )
    }

    private func automaticLocationRow(
        plans: [PlanRecord],
        visibleSpan: TimeSpan,
        index: TimelineBoardDataIndex
    ) -> TimelineRowModel {
        let visiblePlaces = model.snapshot.places
            .filter { $0.span.intersection(with: visibleSpan) != nil }
            .sorted { $0.span.start < $1.span.start }
        let planAllocation = laneAllocation(plans, span: \.span)
        let placeAllocation = laneAllocation(visiblePlaces, span: \.span)
        let offset = planAllocation.count
        let planBlocks = plans.map { plan in
            timelineBlock(
                plan: plan,
                index: index,
                top: compactAutomaticTop(
                    planAllocation.lanes[plan.id, default: 0]
                ),
                height: 14
            )
        }
        let placeBlocks = visiblePlaces.map { place in
            let title = place.floor.map {
                "\(place.displayName) · \($0)층"
            } ?? place.displayName
            let altitude = place.point.map {
                "해발 \(Int($0.altitude.rounded()))m"
                    + (
                        $0.verticalAccuracy >= 0
                            ? " · ±\(Int($0.verticalAccuracy.rounded()))m"
                            : ""
                    )
            }
            return timelineBlock(
                id: place.id,
                title: title,
                span: place.span,
                top: compactAutomaticTop(
                    offset
                        + placeAllocation.lanes[place.id, default: 0]
                ),
                height: 14,
                isFixed: true,
                status: .completed,
                isActual: true,
                opensLocationTimeline: true,
                detailText: [
                    "자동 위치",
                    confidenceName(place.confidence),
                    altitude,
                ]
                .compactMap { $0 }
                .joined(separator: " · "),
                categoryID: "location",
                categoryName: "위치"
            )
        }
        return TimelineRowModel(
            title: "위치",
            id: "location",
            category: .location,
            categoryID: "location",
            isSystemAutomatic: true,
            height: compactAutomaticHeight(
                planAllocation.count + placeAllocation.count
            ),
            blocks: planBlocks + placeBlocks
        )
    }

    private func automaticMovementRow(
        plans: [PlanRecord],
        visibleSpan: TimeSpan,
        index: TimelineBoardDataIndex
    ) -> TimelineRowModel {
        let visibleTravel = model.snapshot.travel
            .filter { $0.span.intersection(with: visibleSpan) != nil }
            .sorted { $0.span.start < $1.span.start }
        let planAllocation = laneAllocation(plans, span: \.span)
        let travelAllocation = laneAllocation(visibleTravel, span: \.span)
        let offset = planAllocation.count
        let planBlocks = plans.map { plan in
            timelineBlock(
                plan: plan,
                index: index,
                top: compactAutomaticTop(
                    planAllocation.lanes[plan.id, default: 0]
                ),
                height: 14
            )
        }
        let travelBlocks = visibleTravel.map { travel in
            timelineBlock(
                id: travel.id,
                title: travelModeName(travel.mode),
                span: travel.span,
                top: compactAutomaticTop(
                    offset
                        + travelAllocation.lanes[travel.id, default: 0]
                ),
                height: 14,
                isFixed: true,
                status: .completed,
                isActual: true,
                opensLocationTimeline: true,
                detailText:
                    "자동 이동 · \(confidenceName(travel.confidence))",
                categoryID: "movement",
                categoryName: "이동"
            )
        }
        return TimelineRowModel(
            title: "이동",
            id: "movement",
            category: .movement,
            categoryID: "movement",
            isSystemAutomatic: true,
            height: compactAutomaticHeight(
                planAllocation.count + travelAllocation.count
            ),
            blocks: planBlocks + travelBlocks
        )
    }

    private func automaticActivityRow(
        _ actuals: [ActualRecord]
    ) -> TimelineRowModel {
        let allocation = laneAllocation(actuals, span: { $0.span() })
        return TimelineRowModel(
            title: "활동",
            id: "activity",
            categoryID: "health",
            dotColor: .tpHealthDark,
            fillColor: .tpHealthArea,
            actualColor: .tpHealthDark,
            isSystemAutomatic: true,
            height: compactAutomaticHeight(allocation.count),
            blocks: actuals.map { actual in
                timelineBlock(
                    id: actual.id,
                    title: actual.title,
                    span: actual.span(),
                    top: compactAutomaticTop(
                        allocation.lanes[actual.id, default: 0]
                    ),
                    height: 14,
                    isFixed: true,
                    status: .completed,
                    isActual: true,
                    detailText:
                        "자동 활동 · \(actualSourceName(actual.source))"
                )
            }
        )
    }

    private func compactAutomaticHeight(_ laneCount: Int) -> CGFloat {
        10 + CGFloat(max(1, laneCount)) * 18
    }

    private func compactAutomaticTop(_ lane: Int) -> CGFloat {
        5 + CGFloat(lane) * 18
    }

    private func calendarDetailText(_ event: CalendarRecord) -> String {
        [
            calendarEventDateTimeLabel(for: event),
            event.sourceTitle,
            event.calendarTitle,
            "고정 일정",
        ]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: " · ")
    }

    private func calendarEventDateTimeLabel(for event: CalendarRecord) -> String {
        let date = calendarDateLabel(event.span.start)
        if event.isAllDay {
            return "\(date) · 종일"
        }
        let start = event.span.start.formatted(date: .omitted, time: .shortened)
        let end = event.span.end.formatted(date: .omitted, time: .shortened)
        return "\(date) · \(start)–\(end)"
    }

    private func calendarDateLabel(_ date: Date) -> String {
        let calendar = Calendar.autoupdatingCurrent
        let weekdaySymbols = ["일", "월", "화", "수", "목", "금", "토"]
        let month = calendar.component(.month, from: date)
        let day = calendar.component(.day, from: date)
        let weekdayIndex = max(
            0,
            min(
                weekdaySymbols.count - 1,
                calendar.component(.weekday, from: date) - 1
            )
        )
        return "\(month)월 \(day)일 (\(weekdaySymbols[weekdayIndex]))"
    }

    private func timelineBlock(
        plan: PlanRecord,
        index: TimelineBoardDataIndex,
        top: CGFloat = 16,
        height: CGFloat = 26
    ) -> TimelineBlock {
        let childCount = index.childCounts[plan.id, default: 0]
        let categoryName = index.categoryNames[plan.categoryID]
            ?? plan.categoryID
        let categoryDetail = categoryPathDetail(
            categoryName: categoryName,
            key: planCategoryPath(for: plan)
        )
        let isGoalPlan = isGoalPlan(
            plan,
            childCount: index.childCounts[plan.id, default: 0]
        )
        let displayTitle = isGoalPlan
            ? goalDisplayTitle(plan.title)
            : plan.title
        return timelineBlock(
            id: plan.id,
            planID: plan.id,
            title: displayTitle,
            span: plan.span,
            top: top,
            height: height,
            isFixed: plan.isFixed,
            groupCount: childCount > 0 ? childCount : nil,
            status: plan.status,
            detailText: isGoalPlan
                ? "목표 · \(categoryDetail)"
                : ["계획", categoryDetail]
                .joined(separator: " · "),
            isGoal: isGoalPlan,
            categoryID: plan.categoryID,
            categoryName: categoryDetail
        )
    }

    private func isGoalPlan(_ plan: PlanRecord, childCount: Int) -> Bool {
        guard plan.parentID == nil else { return false }
        if isExplicitGoalTitle(plan.title) {
            return true
        }
        return childCount > 0
    }

    private func isExplicitGoalTitle(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("목표:")
    }

    private func goalDisplayTitle(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        if trimmed.hasPrefix("목표:") { return trimmed }
        return "목표:\(trimmed)"
    }

    private func timelineBlock(
        actual: ActualRecord,
        index: TimelineBoardDataIndex,
        top: CGFloat = 16,
        height: CGFloat = 26
    ) -> TimelineBlock {
        timelineBlock(
            id: actual.id,
            title: "\(actual.title) · 실제",
            span: actual.span(),
            top: top,
            height: height,
            isFixed: true,
            status: .completed,
            isActual: true,
            detailText:
                "실제 · \(actualSourceName(actual.source)) · \(confidenceName(actual.confidence))",
            categoryID: actual.categoryID,
            categoryName: index.categoryNames[actual.categoryID]
        )
    }

    private func sensorTimelineBlocks(
        categoryID: String,
        top: CGFloat,
        visibleSpan: TimeSpan
    ) -> [TimelineBlock] {
        switch categoryID {
        case "movement":
            return model.snapshot.travel
                .filter {
                    $0.span.intersection(with: visibleSpan) != nil
                }
                .sorted { $0.span.start < $1.span.start }
                .map { travel in
                    timelineBlock(
                        id: travel.id,
                        title: travelModeName(travel.mode),
                        span: travel.span,
                        top: top,
                        height: 16,
                        isFixed: true,
                        status: .completed,
                        isActual: true,
                        opensLocationTimeline: true,
                        detailText:
                            "센서 추정 · \(confidenceName(travel.confidence))",
                        categoryID: "movement",
                        categoryName: "이동"
                    )
                }
        case "location":
            return model.snapshot.places
                .filter {
                    $0.span.intersection(with: visibleSpan) != nil
                }
                .sorted { $0.span.start < $1.span.start }
                .map { place in
                    let title = place.floor.map {
                        "\(place.displayName) · \($0)층"
                    } ?? place.displayName
                    let altitude = place.point.map {
                        "해발 \(Int($0.altitude.rounded()))m"
                            + (
                                $0.verticalAccuracy >= 0
                                    ? " · ±\(Int($0.verticalAccuracy.rounded()))m"
                                    : ""
                            )
                    }
                    return timelineBlock(
                        id: place.id,
                        title: title,
                        span: place.span,
                        top: top,
                        height: 16,
                        isFixed: true,
                        status: .completed,
                        isActual: true,
                        opensLocationTimeline: true,
                        detailText:
                            [
                                "센서 추정",
                                confidenceName(place.confidence),
                                altitude,
                            ]
                            .compactMap { $0 }
                            .joined(separator: " · "),
                        categoryID: "location",
                        categoryName: "위치"
                    )
                }
        default:
            return []
        }
    }

    private func travelModeName(_ mode: TravelMode) -> String {
        switch mode {
        case .walking: "걷기"
        case .running: "달리기"
        case .cycling: "자전거"
        case .bus: "버스"
        case .subway: "지하철"
        case .taxi: "택시"
        case .car: "자가용"
        case .train: "기차"
        case .airplane: "비행기"
        case .ship: "배"
        }
    }

    private func confidenceName(_ confidence: ConfidenceLevel) -> String {
        switch confidence {
        case .low: "낮은 신뢰"
        case .medium: "중간 신뢰"
        case .high: "높은 신뢰"
        }
    }

    private func actualSourceName(_ source: ActualSource) -> String {
        switch source {
        case .manual: "직접 기록"
        case .timer: "타이머"
        case .healthKit: "Apple 건강"
        case .appleWatch: "Apple Watch 센서"
        case .calendar: "캘린더"
        case .location: "위치"
        case .photo: "사진"
        }
    }

    private func laneAllocation<Item: Identifiable>(
        _ items: [Item],
        span: (Item) -> TimeSpan
    ) -> (lanes: [Item.ID: Int], count: Int)
    where Item.ID: Hashable {
        let allocation = TimelineLaneAllocator.allocate(items, span: span)
        return (allocation.lanes, allocation.count)
    }

    private func timelineBlock(
        id: UUID = UUID(),
        planID: UUID? = nil,
        title: String,
        span: TimeSpan,
        top: CGFloat,
        height: CGFloat,
        isFixed: Bool,
        groupCount: Int? = nil,
        actualFraction: Double? = nil,
        status: PlanStatus = .planned,
        isActual: Bool = false,
        opensLocationTimeline: Bool = false,
        detailText: String? = nil,
        isGoal: Bool = false,
        categoryID: String? = nil,
        categoryName: String? = nil
    ) -> TimelineBlock {
        let overlap = span.intersection(with: visibleSpan) ?? span
        let start = CGFloat(
            TimelineAxisGrid.fraction(
                of: overlap.start,
                in: visibleSpan,
                scale: scale
            )
        )
        let end = CGFloat(
            TimelineAxisGrid.fraction(
                of: overlap.end,
                in: visibleSpan,
                scale: scale
            )
        )
        let length = max(0, end - start)
        return TimelineBlock(
            id: id,
            planID: planID,
            title: title,
            start: max(0, min(1, start)),
            length: max(0.012, min(1, length)),
            top: top,
            height: height,
            isFixed: isFixed,
            groupCount: groupCount,
            actualFraction: actualFraction,
            status: status,
            isActual: isActual,
            opensLocationTimeline: opensLocationTimeline,
            startsAt: span.start,
            endsAt: span.end,
            detailText: detailText,
            categoryID: categoryID,
            categoryName: categoryName,
            isGoal: isGoal
        )
    }

    private var isContinuousDay: Bool {
        scale == .day
    }

    private var standardVisibleSpan: TimeSpan {
        TimelineAxisGrid.span(
            for: scale,
            containing: model.selectedDate
        )
    }

    private var visibleSpan: TimeSpan {
        guard isContinuousDay else { return standardVisibleSpan }
        let halfDuration = dayZoom.duration / 2
        return TimeSpan(
            start: continuousCenterDate.addingTimeInterval(-halfDuration),
            end: continuousCenterDate.addingTimeInterval(halfDuration)
        )
    }

    private var groupRows: [TimelineRowModel] {
        [
            .init(
                title: "조사",
                dotColor: .clear,
                blocks: [.init(title: "시장 조사", start: 0.02, length: 0.26)]
            ),
            .init(
                title: "분석",
                dotColor: .clear,
                blocks: [.init(title: "경쟁사 분석", start: 0.16, length: 0.26)]
            ),
            .init(
                title: "컨셉",
                dotColor: .clear,
                blocks: [.init(title: "컨셉 정리", start: 0.30, length: 0.28)]
            ),
            .init(
                title: "초안",
                dotColor: .clear,
                blocks: [.init(title: "보고서 초안", start: 0.58, length: 0.26)]
            ),
        ]
    }

    @ViewBuilder
    private func gridLines(markers: [TimelineAxisMarker]) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: scheduleLabelColumnWidth)
            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    ForEach(markers) { marker in
                        Rectangle()
                            .fill(ganttTableLineColor)
                            .frame(width: 0.5)
                            .position(
                                x: proxy.size.width
                                    * CGFloat(marker.fraction),
                                y: proxy.size.height / 2
                            )
                    }
                }
            }
            .clipped()
        }
    }

    @ViewBuilder
    private func currentLine(at date: Date) -> some View {
        if isContinuousDay {
            GeometryReader { proxy in
                let x = scheduleLabelColumnWidth
                    + max(1, proxy.size.width - scheduleLabelColumnWidth) / 2
                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .fill(Color.tpNow)
                        .frame(width: 2, height: proxy.size.height)
                        .position(x: x, y: proxy.size.height / 2)
                    Circle()
                        .fill(Color.tpNow)
                        .frame(width: 9, height: 9)
                        .position(x: x, y: 1)
                    Text(
                        continuousCenterDate.formatted(
                            date: .omitted,
                            time: .shortened
                        )
                    )
                        .font(.taption(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.tpNow, in: Capsule())
                        .fixedSize()
                        .position(x: x, y: 7)
                }
            }
            .zIndex(20)
        } else if visibleSpan.contains(date) {
            GeometryReader { proxy in
                let timelineWidth = max(
                    1,
                    proxy.size.width - scheduleLabelColumnWidth
                )
                let viewportFraction = (
                    Double(nowFraction(at: date)) - viewport.start
                ) / viewport.length
                let x = scheduleLabelColumnWidth
                    + timelineWidth * CGFloat(viewportFraction)

                if (0...1).contains(viewportFraction) {
                    ZStack(alignment: .topLeading) {
                        Rectangle()
                            .fill(Color.tpNow)
                            .frame(width: 2, height: proxy.size.height)
                            .position(x: x, y: proxy.size.height / 2)
                        Circle()
                            .fill(Color.tpNow)
                            .frame(width: 8, height: 8)
                            .position(x: x, y: 1)
                        if scale == .day, !isGroup {
                            Text(
                                date.formatted(
                                    date: .omitted,
                                    time: .shortened
                                )
                            )
                                .font(.taption(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.tpNow, in: Capsule())
                                .fixedSize()
                                .position(x: x, y: 7)
                        }
                    }
                }
            }
            .zIndex(20)
        }
    }

    private func photoRow(_ clusters: [PhotoCluster]) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.tpPhotoDark)
                    .frame(width: 8, height: 8)
                Text("사진")
                    .font(.taption(size: 10.5, weight: .semibold))
            }
            .foregroundStyle(Color.tpInk)
            .padding(.leading, 8)
            .frame(
                width: scheduleLabelColumnWidth,
                alignment: .leading
            )

            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    ForEach(clusters) { cluster in
                        if let x = photoMarkerX(
                            cluster,
                            width: proxy.size.width
                        ) {
                            photoMarker(cluster: cluster, x: x)
                        }
                    }
                }
            }
            .clipped()
        }
        .frame(height: 65)
        .background(Color(red: 0.99, green: 0.98, blue: 1.00))
        .overlay(alignment: .bottom) {
            Rectangle().fill(ganttTableLineColor).frame(height: 0.5)
        }
    }

    private func photoMarker(
        cluster: PhotoCluster,
        x: CGFloat
    ) -> some View {
        Button {
            onPhotoSelection?(cluster)
        } label: {
            VStack(spacing: 2) {
                ZStack(alignment: .topTrailing) {
                    PhotoAssetThumbnail(
                        model: model,
                        localIdentifier: cluster.representative.id
                    )
                        .frame(width: 39, height: 39)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(.white, lineWidth: 2)
                        }
                        .shadow(color: .black.opacity(0.24), radius: 2.5, y: 1)

                    if cluster.additionalCount > 0 {
                        Text("+\(cluster.additionalCount)")
                            .font(.taption(size: 7, weight: .black))
                            .foregroundStyle(.white)
                            .frame(minWidth: 17, minHeight: 17)
                            .background(Color.tpPhotoDark, in: Capsule())
                            .overlay { Capsule().stroke(.white, lineWidth: 1.5) }
                            .offset(x: 5, y: -5)
                    }
                }
                Text(
                    cluster.capturedAt.formatted(
                        date: .omitted,
                        time: .shortened
                    )
                )
                    .font(.taption(size: 6.5, weight: .black))
                    .foregroundStyle(Color.tpPhotoDark)
            }
        }
        .buttonStyle(.plain)
        .position(
            x: x,
            y: 32
        )
    }

    private func photoMarkerX(
        _ cluster: PhotoCluster,
        width: CGFloat
    ) -> CGFloat? {
        let fraction = TimelineAxisGrid.fraction(
            of: cluster.capturedAt,
            in: visibleSpan,
            scale: scale
        )
        guard viewport.start <= fraction, fraction <= viewport.end else {
            return nil
        }
        let viewportFraction =
            (fraction - viewport.start) / viewport.length
        return min(
            width - 22,
            max(22, width * CGFloat(viewportFraction))
        )
    }

    private func summaryStrip(
        buckets: [SummaryBucket],
        colors: [SummaryColor]
    ) -> some View {
        HStack(spacing: 0) {
            Text(summaryTitle)
                .font(.taption(size: scale == .month ? 9 : 10, weight: .regular))
                .foregroundStyle(Color.tpSecondary)
                .padding(.leading, scale == .month ? 4 : 8)
                .frame(
                    width: scheduleLabelColumnWidth,
                    alignment: .leading
                )

            HStack(spacing: 3) {
                ForEach(colors.indices, id: \.self) { index in
                    Button {
                        zoomIntoSummary(buckets[index])
                    } label: {
                        ZStack {
                            RoundedRectangle(
                                cornerRadius: 5,
                                style: .continuous
                            )
                            .fill(
                                colors[index].color.opacity(
                                    colors[index].opacity
                                )
                            )
                            if buckets[index].photoCount > 0 {
                                HStack(spacing: 1) {
                                    Image(systemName: "photo.fill")
                                    Text(
                                        "\(buckets[index].photoCount)"
                                    )
                                }
                                .font(.taption(size: 6.5, weight: .black))
                                .foregroundStyle(Color.tpPhotoDark)
                            }
                        }
                        .frame(height: 18)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        summaryAccessibilityLabel(
                            buckets[index]
                        )
                    )
                }
            }
            .padding(.horizontal, 3)
        }
        .frame(height: 46)
        .background(Color(red: 0.98, green: 0.98, blue: 0.985))
        .overlay(alignment: .bottom) {
            Rectangle().fill(ganttTableLineColor).frame(height: 0.5)
        }
    }

    private func planActualStrip(
        plannedDuration: TimeInterval,
        actualDuration: TimeInterval
    ) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "chart.bar.fill")
                .font(.taption(size: 8, weight: .bold))
                .foregroundStyle(Color.tpProjectDark)
            Text("계획")
                .foregroundStyle(Color.tpSecondary)
            Text(durationLabel(plannedDuration))
                .fontWeight(.black)
            Text("· 실제")
                .foregroundStyle(Color.tpSecondary)
            Text(durationLabel(actualDuration))
                .fontWeight(.black)
                .foregroundStyle(Color.tpProjectDark)
        }
        .font(.taption(size: 9))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Color.tpProject.opacity(0.45),
            in: Capsule()
        )
        .frame(maxWidth: .infinity, minHeight: 30)
        .overlay(alignment: .bottom) {
            Rectangle().fill(ganttTableLineColor).frame(height: 0.5)
        }
        .accessibilityElement(children: .combine)
    }

    private var summaryTitle: String {
        switch scale {
        case .week, .day: "일 요약"
        case .month: "주·일 요약"
        case .year: "월·주·일 요약"
        }
    }

    private func summaryColors(
        for buckets: [SummaryBucket]
    ) -> [SummaryColor] {
        let maximum = max(
            1,
            buckets.map {
                max($0.actualDuration, $0.plannedDuration)
            }.max() ?? 1
        )
        return buckets.map { bucket in
            let dominant = bucket.categories.max {
                max($0.actual, $0.planned) < max($1.actual, $1.planned)
            }
            let definition = dominant.flatMap { value in
                model.snapshot.categories.first {
                    $0.id == value.categoryID
                }
            }
            let activity = max(bucket.actualDuration, bucket.plannedDuration)
            return SummaryColor(
                Color(hex: definition?.darkHex ?? "#D9D9DD"),
                activity == 0 ? 0.18 : 0.25 + 0.70 * activity / maximum
            )
        }
    }

    private func nowFraction(at date: Date) -> CGFloat {
        max(
            0,
            min(
                1,
                CGFloat(
                    TimelineAxisGrid.fraction(
                        of: date,
                        in: visibleSpan,
                        scale: scale
                    )
                )
            )
        )
    }

    private var viewportMinimumLength: Double {
        GanttViewport.oneMinuteMinimumLength(
            for: visibleSpan.duration
        )
    }

    private var currentZoomStage: GanttZoomStage {
        GanttZoomStage.nearest(
            to: visibleSpan.duration * viewport.length
        )
    }

    private var viewportVisibleSpan: TimeSpan {
        TimeSpan(
            start: TimelineAxisGrid.date(
                at: viewport.start,
                in: visibleSpan,
                scale: scale
            ),
            end: TimelineAxisGrid.date(
                at: viewport.end,
                in: visibleSpan,
                scale: scale
            )
        )
    }

    private func axisMarkers(in visibleSpan: TimeSpan) -> [TimelineAxisMarker] {
        if isContinuousDay {
            return continuousAxisMarkers
        }
        guard !viewport.isFull else {
            return TimelineAxisGrid.buckets(
                for: scale,
                containing: model.selectedDate
            ).map { bucket in
                TimelineAxisMarker(
                    id: "full-\(bucket.id)",
                    fraction: Double(bucket.index) / Double(bucket.count),
                    label: bucket.label,
                    isCurrent: isCurrentBucket(bucket),
                    holidayName: bucket.holidayName
                )
            }
        }

        let span = viewportVisibleSpan
        let step = axisTickInterval
        let start = span.start.timeIntervalSinceReferenceDate
        let end = span.end.timeIntervalSinceReferenceDate
        var next = ceil(start / step) * step
        var markers: [TimelineAxisMarker] = []

        while next <= end, markers.count < 64 {
            let date = Date(timeIntervalSinceReferenceDate: next)
            markers.append(
                TimelineAxisMarker(
                    id: "zoom-\(next)",
                    fraction: (next - start) / max(1, end - start),
                    label: axisTickLabel(date),
                    isCurrent: abs(date.timeIntervalSinceNow) < step / 2
                )
            )
            next += step
        }

        if markers.isEmpty {
            let date = span.start.addingTimeInterval(span.duration / 2)
            return [
                TimelineAxisMarker(
                    id: "zoom-center-\(date.timeIntervalSinceReferenceDate)",
                    fraction: 0.5,
                    label: axisTickLabel(date),
                    isCurrent: span.contains(.now)
                )
            ]
        }
        return markers
    }

    private var continuousAxisMarkers: [TimelineAxisMarker] {
        let span = visibleSpan
        let step: TimeInterval
        switch dayZoom.duration {
        case ...Double(5 * 60): step = 60
        case ...Double(15 * 60): step = 5 * 60
        case ...Double(60 * 60): step = 15 * 60
        case ...Double(6 * 60 * 60): step = 60 * 60
        case ...Double(24 * 60 * 60): step = 12 * 60 * 60
        case ...Double(3 * 24 * 60 * 60): step = 12 * 60 * 60
        default: step = 24 * 60 * 60
        }
        let start = span.start.timeIntervalSinceReferenceDate
        let end = span.end.timeIntervalSinceReferenceDate
        let calendar = TimelineAxisGrid.normalizedCalendar()
        var nextDate = calendar.startOfDay(for: span.start)
        let minuteStep = max(1, Int(step / 60))
        while nextDate < span.start {
            nextDate = calendar.date(
                byAdding: .minute,
                value: minuteStep,
                to: nextDate
            ) ?? nextDate.addingTimeInterval(step)
        }
        var next = nextDate.timeIntervalSinceReferenceDate
        var markers: [TimelineAxisMarker] = []
        while next <= end, markers.count < 64 {
            let date = Date(timeIntervalSinceReferenceDate: next)
            let label: String
            if dayZoom.duration <= 60 * 60 {
                label = axisHourMinuteLabel(date, calendar: calendar)
            } else if dayZoom.duration <= 24 * 60 * 60 {
                let hour = calendar.component(.hour, from: date)
                label = String(format: "%02d", hour)
            } else {
                label = "\(calendar.component(.month, from: date))/\(calendar.component(.day, from: date))"
            }
            markers.append(
                TimelineAxisMarker(
                    id: "continuous-\(next)",
                    fraction: (next - start) / max(1, end - start),
                    label: label,
                    isCurrent: abs(date.timeIntervalSince(continuousCenterDate)) < step / 2
                )
            )
            next += step
        }
        return markers
    }

    private func isCurrentBucket(_ bucket: TimelineAxisBucket) -> Bool {
        switch scale {
        case .week:
            return TimelineAxisGrid.normalizedCalendar().isDate(
                bucket.date,
                inSameDayAs: model.selectedDate
            )
        case .month:
            return TimelineAxisGrid.normalizedCalendar().isDate(
                bucket.date,
                equalTo: model.selectedDate,
                toGranularity: .day
            )
        case .year:
            return TimelineAxisGrid.normalizedCalendar().isDate(
                bucket.date,
                equalTo: model.selectedDate,
                toGranularity: .month
            )
        case .day:
            return false
        }
    }

    private var axisTickInterval: TimeInterval {
        let target = viewportVisibleSpan.duration / 6
        let supportedSteps: [TimeInterval] = [
            60,
            5 * 60,
            15 * 60,
            30 * 60,
            60 * 60,
            3 * 60 * 60,
            6 * 60 * 60,
            12 * 60 * 60,
            24 * 60 * 60,
            2 * 24 * 60 * 60,
            5 * 24 * 60 * 60,
            7 * 24 * 60 * 60,
            14 * 24 * 60 * 60,
            30 * 24 * 60 * 60,
            90 * 24 * 60 * 60,
        ]
        return supportedSteps.first { $0 >= target }
            ?? supportedSteps.last!
    }

    private func axisTickLabel(_ date: Date) -> String {
        let calendar = Calendar.autoupdatingCurrent
        if viewportVisibleSpan.duration <= 60 * 60 {
            return axisHourMinuteLabel(date, calendar: calendar)
        }
        if viewportVisibleSpan.duration <= 2 * 24 * 60 * 60 {
            return String(format: "%02d", calendar.component(.hour, from: date))
        }
        if viewportVisibleSpan.duration <= 90 * 24 * 60 * 60 {
            return "\(calendar.component(.month, from: date)).\(calendar.component(.day, from: date))"
        }
        return "\(calendar.component(.month, from: date))월"
    }

    private func axisHourMinuteLabel(
        _ date: Date,
        calendar: Calendar
    ) -> String {
        String(
            format: "%02d:%02d",
            calendar.component(.hour, from: date),
            calendar.component(.minute, from: date)
        )
    }

    private func markerX(
        _ marker: TimelineAxisMarker,
        width: CGFloat
    ) -> CGFloat {
        min(
            max(18, width - 18),
            max(18, width * CGFloat(marker.fraction))
        )
    }

    private var currentAxisLabel: String {
        let calendar = Calendar.autoupdatingCurrent
        return switch scale {
        case .day:
            String(format: "%02d", calendar.component(.hour, from: .now))
        case .week:
            Date.now.formatted(
                Date.FormatStyle()
                    .weekday(.short)
                    .locale(Locale(identifier: "ko_KR"))
            )
        case .month:
            "\(calendar.component(.day, from: .now))"
        case .year:
            "\(calendar.component(.month, from: .now))"
        }
    }

    private func photoClusters(in visibleSpan: TimeSpan) -> [PhotoCluster] {
        PhotoClusterer.cluster(
            model.snapshot.photos.filter {
                visibleSpan.contains($0.capturedAt)
            }
        )
    }

    private func visibleActualDuration(in visibleSpan: TimeSpan) -> TimeInterval {
        model.snapshot.actuals.reduce(0) { result, actual in
            result
                + (actual.span().intersection(with: visibleSpan)?.duration
                    ?? 0)
        }
    }

    private func visiblePlannedDuration(
        in visibleSpan: TimeSpan,
        parentPlanIDs: Set<UUID>
    ) -> TimeInterval {
        let leafPlans = storedPlans.filter { plan in
            plan.span.intersection(with: visibleSpan) != nil
                && !parentPlanIDs.contains(plan.id)
        }
        return leafPlans.reduce(0) { result, plan in
            result
                + (plan.span.intersection(with: visibleSpan)?.duration ?? 0)
        }
    }

    private func durationLabel(_ interval: TimeInterval) -> String {
        let minutes = max(0, Int(interval / 60))
        let hours = minutes / 60
        let remainder = minutes % 60
        if hours == 0 { return "\(remainder)분" }
        if remainder == 0 { return "\(hours)시간" }
        return "\(hours)시간 \(remainder)분"
    }

    private func summaryBuckets(in visibleSpan: TimeSpan) -> [SummaryBucket] {
        let childLevel: TimelineLevel
        switch scale {
        case .day:
            return []
        case .week:
            childLevel = .day
        case .month:
            childLevel = .week
        case .year:
            childLevel = .month
        }
        return TimelineAggregationEngine().hierarchySummaries(
            for: scale.timelineLevel,
            containing: model.selectedDate,
            plans: model.snapshot.plans,
            actuals: model.snapshot.actuals,
            photos: model.snapshot.photos
        )[childLevel] ?? []
    }

    private func zoomIntoSummary(_ bucket: SummaryBucket) {
        model.selectedDate = bucket.span.start
        switch scale {
        case .week:
            model.selectScale(.day)
        case .month:
            model.selectScale(.week)
        case .year:
            model.selectScale(.month)
        case .day:
            break
        }
    }

    private func summaryAccessibilityLabel(
        _ bucket: SummaryBucket
    ) -> String {
        let range =
            bucket.span.start.formatted(.dateTime.month().day())
            + "부터 "
            + bucket.span.end.addingTimeInterval(-1)
                .formatted(.dateTime.month().day())
        let photoText = bucket.photoCount > 0
            ? ", 사진 \(bucket.photoCount)장"
            : ""
        return "\(range) 요약\(photoText), 탭하여 확대"
    }

    private func viewportDragGesture(
        width: CGFloat
    ) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard editingPlanID == nil,
                      abs(value.translation.width)
                        > abs(value.translation.height) else {
                    return
                }
                if isContinuousDay {
                    if continuousDragOrigin == nil {
                        continuousDragOrigin = continuousCenterDate
                        editingPlanID = nil
                        lastContinuousRenderUptime = 0
                    }
                    guard let continuousDragOrigin else { return }
                    let secondsPerPoint = dayZoom.duration / Double(max(1, width))
                    let candidate = continuousDragOrigin.addingTimeInterval(
                        -Double(value.translation.width) * secondsPerPoint
                    )
                    let uptime = ProcessInfo.processInfo.systemUptime
                    guard lastContinuousRenderUptime == 0
                        || uptime - lastContinuousRenderUptime >= 1.0 / 60.0
                    else {
                        return
                    }
                    lastContinuousRenderUptime = uptime
                    continuousCenterDate = candidate
                    onPlayheadMove?(continuousCenterDate)
                } else {
                    if dragOrigin == nil {
                        dragOrigin = viewport
                    }
                    guard let dragOrigin else { return }
                    viewport = dragOrigin.panning(
                        translation: Double(value.translation.width),
                        viewportWidth: Double(width)
                    )
                }
            }
            .onEnded { value in
                if isContinuousDay {
                    if let continuousDragOrigin {
                        let secondsPerPoint = dayZoom.duration
                            / Double(max(1, width))
                        continuousCenterDate = continuousDragOrigin
                            .addingTimeInterval(
                                -Double(value.translation.width)
                                    * secondsPerPoint
                            )
                    }
                    model.selectedDate = continuousCenterDate
                    onPlayheadMove?(continuousCenterDate)
                    lastContinuousRenderUptime = 0
                }
                dragOrigin = nil
                continuousDragOrigin = nil
            }
    }

    private var viewportMagnifyGesture: some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.01)
            .onChanged { value in
                if isContinuousDay {
                    if continuousZoomDurationOrigin == nil {
                        continuousZoomDurationOrigin = dayZoom.duration
                        editingPlanID = nil
                    }
                    guard let continuousZoomDurationOrigin else { return }
                    let target = continuousZoomDurationOrigin
                        / max(0.01, Double(value.magnification))
                    dayZoom = TimelineZoomPreset.nearest(to: target)
                    return
                }
                if magnifyOrigin == nil {
                    magnifyOrigin = viewport
                    editingPlanID = nil
                }
                guard let magnifyOrigin else { return }
                viewport = magnifyOrigin.magnifying(
                    by: Double(value.magnification),
                    anchor: Double(value.startAnchor.x),
                    minimumLength: viewportMinimumLength
                )
            }
            .onEnded { value in
                if isContinuousDay {
                    continuousZoomDurationOrigin = nil
                    zoomFeedbackSequence += 1
                    return
                }
                finishSemanticMagnification(
                    factor: Double(value.magnification),
                    anchor: Double(value.startAnchor.x)
                )
                magnifyOrigin = nil
            }
    }

    private func finishSemanticMagnification(
        factor: Double,
        anchor: Double
    ) {
        if isContinuousDay {
            continuousZoomDurationOrigin = nil
            zoomFeedbackSequence += 1
            return
        }
        let origin = magnifyOrigin ?? viewport
        let zoomsIn = factor >= 1.15
        let zoomsOut = factor <= 0.85
        guard zoomsIn || zoomsOut else {
            viewport = origin
            return
        }

        if scale != .day {
            let targetScale = zoomsIn ? scale.narrower : scale.broader
            guard let targetScale else {
                viewport = origin
                return
            }
            transitionScale(
                to: targetScale,
                origin: origin,
                anchor: anchor
            )
            return
        }

        let originStage = GanttZoomStage.nearest(
            to: visibleSpan.duration * origin.length
        )
        if zoomsOut, originStage == .day {
            guard let broader = scale.broader else {
                viewport = origin
                return
            }
            transitionScale(
                to: broader,
                origin: origin,
                anchor: anchor
            )
            return
        }

        let targetStage = zoomsIn
            ? originStage.narrower
            : originStage.broader
        guard let targetStage, targetStage >= .day else {
            viewport = origin
            return
        }
        viewport = origin.fitting(
            visibleDuration: targetStage.duration,
            within: visibleSpan.duration,
            anchor: anchor
        )
        zoomFeedbackSequence += 1
    }

    private func transitionScale(
        to targetScale: TimeScale,
        origin: GanttViewport,
        anchor: Double
    ) {
        let clampedAnchor = min(1, max(0, anchor))
        let anchorFraction =
            origin.start + origin.length * clampedAnchor
        model.selectedDate = TimelineAxisGrid.date(
            at: anchorFraction,
            in: visibleSpan,
            scale: scale
        )
        viewport = .full
        model.selectScale(targetScale)
        zoomFeedbackSequence += 1
    }

    private func resetViewport(withFeedback: Bool = false) {
        let changed = isContinuousDay
            ? dayZoom != .oneDay
            : !viewport.isFull
        if isContinuousDay {
            dayZoom = .oneDay
            continuousDragOrigin = nil
            continuousZoomDurationOrigin = nil
        }
        viewport = .full
        dragOrigin = nil
        magnifyOrigin = nil
        editingPlanID = nil
        if withFeedback, changed {
            zoomFeedbackSequence += 1
        }
    }

    private func handleRowTap(_ row: TimelineRowModel) {
        selectedRowID = row.id
        let selectableBlocks = row.blocks
            .filter { !$0.isActual && $0.planID != nil }
            .sorted {
                ($0.startsAt ?? .distantPast) < ($1.startsAt ?? .distantPast)
            }
        if let block = selectableBlocks.first {
            onSelection?(selectionFromBlock(block))
            return
        }

        guard let categoryID = row.categoryID else { return }
        if categoryID == "calendar" {
            onSelection?(
                TimelineSelection(
                    title: "일정",
                    span: visibleSpan,
                    planID: nil,
                    isRoute: false,
                    categoryID: "calendar",
                    categoryName: "일정"
                )
            )
            return
        }
        let memoPlan = model.memoPlan(
            forCategoryID: categoryID,
            categoryName: row.title,
            near: model.selectedDate
        )
        onSelection?(
            TimelineSelection(
                title: row.title,
                span: memoPlan.span,
                planID: memoPlan.id,
                isRoute: categoryID == "movement" || categoryID == "location",
                categoryID: categoryID,
                categoryName: row.title
            )
        )
    }

    private func focusOnBlock(_ block: TimelineBlock) {
        let selection = selectionFromBlock(block)
        onFocus?(selection)
        onSelection?(selection)

        if isContinuousDay,
           let startsAt = block.startsAt,
           let endsAt = block.endsAt {
            continuousCenterDate = startsAt.addingTimeInterval(
                max(0, endsAt.timeIntervalSince(startsAt)) / 2
            )
            model.selectedDate = continuousCenterDate
            dayZoom = TimelineZoomPreset.nearest(
                to: max(60, endsAt.timeIntervalSince(startsAt) * 6)
            )
            editingPlanID = nil
            zoomFeedbackSequence += 1
            return
        }
        let blockStart: Double
        let blockLength: Double
        if let startsAt = block.startsAt,
           let endsAt = block.endsAt {
            blockStart = TimelineAxisGrid.fraction(
                of: startsAt,
                in: visibleSpan,
                scale: scale
            )
            blockLength = TimelineAxisGrid.fraction(
                of: endsAt,
                in: visibleSpan,
                scale: scale
            ) - blockStart
        } else {
            blockStart = Double(block.start)
            blockLength = Double(block.length)
        }

        viewport = GanttViewport.full.focusing(
            start: blockStart,
            length: blockLength,
            minimumLength: viewportMinimumLength
        )
        editingPlanID = nil
        zoomFeedbackSequence += 1
    }

    private func handleTap(_ block: TimelineBlock) {
        onSelection?(
            selectionFromBlock(block)
        )
        if block.opensLocationTimeline {
            return
        }

        if block.groupCount != nil {
            if let planID = block.planID {
                model.openGroup(planID)
            }
            return
        }

    }

    private func selectionFromBlock(_ block: TimelineBlock) -> TimelineSelection {
        let selectionSpan: TimeSpan = {
            if let startsAt = block.startsAt, let endsAt = block.endsAt {
                return TimeSpan(start: startsAt, end: endsAt)
            }
            let start = TimelineAxisGrid.date(
                at: Double(block.start),
                in: visibleSpan,
                scale: scale
            )
            let end = TimelineAxisGrid.date(
                at: min(1, Double(block.start + block.length)),
                in: visibleSpan,
                scale: scale
            )
            return TimeSpan(
                start: start,
                end: max(
                    start.addingTimeInterval(60),
                    end
                )
            )
        }()
        return TimelineSelection(
            title: block.title,
            span: selectionSpan,
            planID: block.planID,
            actualID: block.isActual
                && model.snapshot.actuals.contains(where: { $0.id == block.id })
                ? block.id
                : nil,
            travelID: block.categoryID == "movement" ? block.id : nil,
            isRoute: block.opensLocationTimeline,
            categoryID: block.categoryID,
            categoryName: block.categoryName
        )
    }
}

private struct TimelineBlockSlice {
    let centerX: CGFloat
    let width: CGFloat
}

private struct TimelineRow: View {
    let row: TimelineRowModel
    let isSelected: Bool
    let editingPlanID: UUID?
    let visibleDuration: TimeInterval
    let viewport: GanttViewport
    let onBlockTap: (TimelineBlock) -> Void
    let onBlockDoubleTap: (TimelineBlock) -> Void
    let onEdit: (UUID?) -> Void
    let onMove: (TimelineBlock, TimeInterval) -> Void
    let onResizeStart: (TimelineBlock, TimeInterval) -> Void
    let onResizeEnd: (TimelineBlock, TimeInterval) -> Void
    let onRowTap: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onRowTap) {
                HStack(spacing: 4) {
                    if row.dotColor != .clear {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(row.dotColor)
                            .frame(width: 8, height: 8)
                    }
                    Text(row.title)
                        .lineLimit(row.title.contains("\n") ? 3 : 1)
                        .minimumScaleFactor(0.78)
                        .lineSpacing(1)
                }
                .font(
                    .taption(
                        size: row.title.contains("\n")
                            ? 8.4
                            : (row.title.count > 4 ? 9 : 10.5),
                        weight: .semibold
                    )
                )
                .foregroundStyle(isSelected ? Color.tpInk : Color.tpInk)
                .padding(.leading, row.title.count > 4 ? 4 : 8)
                .padding(.trailing, 2)
                .frame(
                    width: scheduleLabelColumnWidth,
                    height: row.height,
                    alignment: .leading
                )
                .background(
                    isSelected
                        ? Color.tpInk.opacity(0.06)
                        : Color.clear
                )
                .overlay(alignment: .leading) {
                    if isSelected {
                        Rectangle()
                            .fill(Color.tpInk)
                            .frame(width: 3)
                    }
                }
            }
            .buttonStyle(.plain)
            .simultaneousGesture(
                TapGesture().onEnded {
                    onEdit(nil)
                }
            )

            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            onEdit(nil)
                        }

                    if row.isSystemAutomatic {
                        Rectangle()
                            .fill(Color.tpInk.opacity(0.026))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }

                    ForEach(row.blocks) { block in
                        if let slice = visibleSlice(
                            for: block,
                            width: proxy.size.width
                        ) {
                            TimelineBar(
                                block: block,
                                color: row.fillColor,
                                actualColor: row.actualColor,
                                width: slice.width,
                                isEditing: editingPlanID == block.planID,
                                visibleDuration: visibleDuration,
                                secondsPerPoint:
                                    visibleDuration
                                    / max(1, proxy.size.width),
                                onTap: {
                                    if block.planID == nil {
                                        onEdit(nil)
                                    }
                                    onBlockTap(block)
                                },
                                onDoubleTap: {
                                    onBlockDoubleTap(block)
                                },
                                onEdit: { onEdit(block.planID) },
                                onMove: { onMove(block, $0) },
                                onResizeStart: {
                                    onResizeStart(block, $0)
                                },
                                onResizeEnd: {
                                    onResizeEnd(block, $0)
                                }
                            )
                                .position(
                                    x: slice.centerX,
                                    y: block.top + block.height / 2
                                )
                        }
                    }
                }
            }
            .clipped()
        }
        .background(
            row.isSystemAutomatic
                ? Color.tpInk.opacity(0.018)
                : Color.clear
        )
        .frame(height: row.height)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(ganttTableLineColor)
                .frame(height: 0.5)
        }
    }

    private func visibleSlice(
        for block: TimelineBlock,
        width: CGFloat
    ) -> TimelineBlockSlice? {
        let blockStart = Double(block.start)
        let blockEnd = blockStart + Double(block.length)
        let overlapStart = max(blockStart, viewport.start)
        let overlapEnd = min(blockEnd, viewport.end)
        guard overlapStart < overlapEnd else { return nil }

        let startFraction =
            (overlapStart - viewport.start) / viewport.length
        let endFraction =
            (overlapEnd - viewport.start) / viewport.length
        let naturalWidth =
            width * CGFloat(endFraction - startFraction)
        return TimelineBlockSlice(
            centerX:
                width * CGFloat((startFraction + endFraction) / 2),
            width: max(block.minimumWidth, naturalWidth)
        )
    }
}

private struct TimelineBar: View {
    let block: TimelineBlock
    let color: Color
    let actualColor: Color
    let width: CGFloat
    let isEditing: Bool
    let visibleDuration: TimeInterval
    let secondsPerPoint: TimeInterval
    let onTap: () -> Void
    let onDoubleTap: () -> Void
    let onEdit: () -> Void
    let onMove: (TimeInterval) -> Void
    let onResizeStart: (TimeInterval) -> Void
    let onResizeEnd: (TimeInterval) -> Void

    var body: some View {
        HStack(spacing: 3) {
            Text(primaryText)
                .font(.taption(size: block.height <= 20 ? 9.5 : 10.5, weight: .semibold))
                .foregroundStyle(
                    block.isActual
                        ? Color.white
                        : Color.tpInk.opacity(0.64)
                )
                .lineLimit(1)
                .minimumScaleFactor(0.72)

            if !showsMinuteDetails, let count = block.groupCount {
                Spacer(minLength: 1)
                Text("▸ \(count)")
                    .font(.taption(size: 8.5, weight: .bold))
                    .foregroundStyle(Color.tpInk.opacity(0.62))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.white.opacity(0.70), in: Capsule())
            }
            if !showsMinuteDetails, block.status == .completed {
                Image(systemName: "checkmark.circle.fill")
                    .font(.taption(size: 9, weight: .bold))
                    .foregroundStyle(actualColor)
            }
        }
        .padding(.horizontal, 6)
        .frame(
            width: width,
            height: block.height,
            alignment: .leading
        )
        .background {
            if block.isGoal {
                GoalStripeBackground(
                    tint: color.opacity(0.76)
                )
            } else if block.isFixed {
                if block.isActual {
                    actualColor.opacity(0.82)
                } else {
                    FixedStripeBackground()
                }
            } else {
                color
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: block.height <= 20 ? 10 : 7, style: .continuous))
        .overlay {
            if block.isFixed {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(
                        block.isActual
                            ? actualColor
                            : Color(
                                red: 0.78,
                                green: 0.78,
                                blue: 0.80
                            ),
                        lineWidth: 1
                    )
            } else if block.isGoal {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(
                        color,
                        lineWidth: 1.1
                    )
            }
        }
        .overlay(alignment: .bottomLeading) {
            if let fraction = block.actualFraction, fraction > 0 {
                Capsule()
                    .fill(actualColor)
                    .frame(
                        width: max(4, width * CGFloat(fraction)),
                        height: 3
                    )
                    .padding(.horizontal, 2)
                    .padding(.bottom, 2)
            }
        }
        .overlay {
            if isEditing, block.planID != nil {
                HStack {
                    resizeHandle
                        .gesture(
                            DragGesture(minimumDistance: 1)
                                .onEnded {
                                    onResizeStart(
                                        $0.translation.width * secondsPerPoint
                                    )
                                }
                        )
                    Spacer()
                    resizeHandle
                        .gesture(
                            DragGesture(minimumDistance: 1)
                                .onEnded {
                                    onResizeEnd(
                                        $0.translation.width * secondsPerPoint
                                    )
                                }
                        )
                }
                .padding(.horizontal, -5)
            }
        }
        .highPriorityGesture(
            TapGesture(count: 2)
                .exclusively(before: TapGesture(count: 1))
                .onEnded { value in
                    switch value {
                    case .first:
                        onDoubleTap()
                    case .second:
                        onTap()
                    }
                }
        )
        .onLongPressGesture(
            minimumDuration: 0.18,
            maximumDistance: 12,
            perform: onEdit
        )
        .simultaneousGesture(
            DragGesture(minimumDistance: 12)
                .onEnded {
                    guard isEditing, block.planID != nil else { return }
                    onMove($0.translation.width * secondsPerPoint)
                }
        )
        .accessibilityHint(
            block.isFixed
                ? "두 번 탭하면 일정에 맞춰 확대합니다"
                : "두 번 탭하면 확대하고, 길게 누른 뒤 드래그하면 이동하며 양 끝점을 끌면 길이를 조절합니다"
        )
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            onTap()
        }
    }

    private var showsMinuteDetails: Bool {
        visibleDuration
            <= GanttZoomStage.oneMinute.duration * 1.15
    }

    private var primaryText: String {
        GanttPrecisionPresentation.label(
            title: block.title,
            startsAt: block.startsAt,
            endsAt: block.endsAt,
            detailText: block.detailText,
            visibleDuration: visibleDuration
        )
    }

    private var resizeHandle: some View {
        Circle()
            .fill(Color.white)
            .frame(width: 12, height: 12)
            .overlay {
                Circle().stroke(Color.tpInk.opacity(0.65), lineWidth: 1.5)
            }
            .shadow(color: .black.opacity(0.16), radius: 2)
    }
}

private struct GoalStripeBackground: View {
    let tint: Color

    var body: some View {
        Canvas { context, size in
            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .color(tint.opacity(0.22))
            )

            var path = Path()
            var x: CGFloat = -size.height
            while x < size.width + size.height {
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += 10
            }
            context.stroke(
                path,
                with: .color(tint.opacity(0.6)),
                style: StrokeStyle(
                    lineWidth: 2.8,
                    lineCap: .round,
                    lineJoin: .round
                )
            )
        }
    }
}

private struct TimelineRowModel: Identifiable {
    let id: String
    let title: String
    let category: PlanCategory?
    let categoryID: String?
    let dotColor: Color
    let customFillColor: Color?
    let customActualColor: Color?
    let isSystemAutomatic: Bool
    let height: CGFloat
    let blocks: [TimelineBlock]

    init(
        title: String,
        id: String? = nil,
        category: PlanCategory? = nil,
        categoryID: String? = nil,
        dotColor: Color? = nil,
        fillColor: Color? = nil,
        actualColor: Color? = nil,
        isSystemAutomatic: Bool = false,
        height: CGFloat = 60,
        blocks: [TimelineBlock]
    ) {
        self.id = id ?? categoryID ?? title
        self.title = title
        self.category = category
        self.categoryID = categoryID
        self.dotColor = dotColor ?? category?.darkColor ?? .clear
        self.customFillColor = fillColor
        self.customActualColor = actualColor
        self.isSystemAutomatic = isSystemAutomatic
        self.height = height
        self.blocks = blocks
    }

    var fillColor: Color {
        customFillColor
            ?? category?.color
            ?? Color(red: 0.94, green: 0.94, blue: 0.95)
    }

    var actualColor: Color {
        customActualColor
            ?? category?.darkColor
            ?? Color.tpSecondary
    }
}

private struct TimelineBlock: Identifiable {
    let id: UUID
    let planID: UUID?
    let title: String
    let isGoal: Bool
    let start: CGFloat
    let length: CGFloat
    let top: CGFloat
    let height: CGFloat
    let isFixed: Bool
    let groupCount: Int?
    let actualFraction: Double?
    let status: PlanStatus
    let isActual: Bool
    let opensLocationTimeline: Bool
    let minimumWidth: CGFloat
    let startsAt: Date?
    let endsAt: Date?
    let detailText: String?
    let categoryID: String?
    let categoryName: String?

    init(
        id: UUID = UUID(),
        planID: UUID? = nil,
        title: String,
        start: CGFloat,
        length: CGFloat,
        top: CGFloat = 16,
        height: CGFloat = 26,
        isFixed: Bool = false,
        groupCount: Int? = nil,
        actualFraction: Double? = nil,
        status: PlanStatus = .planned,
        isActual: Bool = false,
        opensLocationTimeline: Bool = false,
        minimumWidth: CGFloat = 18,
        startsAt: Date? = nil,
        endsAt: Date? = nil,
        detailText: String? = nil,
        categoryID: String? = nil,
        categoryName: String? = nil,
        isGoal: Bool = false
    ) {
        self.id = id
        self.planID = planID
        self.title = title
        self.isGoal = isGoal
        self.start = start
        self.length = length
        self.top = top
        self.height = height
        self.isFixed = isFixed
        self.groupCount = groupCount
        self.actualFraction = actualFraction
        self.status = status
        self.isActual = isActual
        self.opensLocationTimeline = opensLocationTimeline
        self.minimumWidth = minimumWidth
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.detailText = detailText
        self.categoryID = categoryID
        self.categoryName = categoryName
    }
}

private struct SummaryColor {
    let color: Color
    let opacity: Double

    init(_ color: Color, _ opacity: Double) {
        self.color = color
        self.opacity = opacity
    }
}

private struct PhotoAssetThumbnail: View {
    @Bindable var model: AppModel
    let localIdentifier: String
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    LinearGradient(
                        colors: [.tpPhoto, .tpPhotoDark.opacity(0.72)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Image(systemName: "photo")
                        .font(.taption(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
        }
        .clipped()
        .task(id: localIdentifier) {
            guard image == nil else { return }
            guard let data = try? await model.photoThumbnailData(
                localIdentifier: localIdentifier,
                size: CGSize(width: 120, height: 120)
            ) else {
                return
            }
            image = UIImage(data: data)
        }
    }
}

#Preview {
    ScheduleView(model: AppModel())
}
