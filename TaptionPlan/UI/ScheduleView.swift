import SwiftUI
import UIKit
import MapKit

let scheduleLabelColumnWidth: CGFloat = 64
let ganttTableLineColor = Color.tpLine.opacity(0.30)
let detailPanelCollapsedHeight: CGFloat = 300
let detailPanelMinimumHeight: CGFloat = 220
let minimumTimelineBoardHeight: CGFloat = 120

struct ScheduleView: View {
    @Bindable var model: AppModel
    @State private var dayZoom: TimelineZoomPreset = .oneHour
    @State private var selectedTimelineItem: TimelineSelection?
    @State private var detailSection: TimelineDetailSection = .map
    @State private var selectedPhotoCluster: PhotoCluster?
    @State private var routeReadings: [SensorReading] = []
    @State private var editingPlanID: UUID?
    @State private var mapPlayheadDate: Date?
    @State private var playheadDetailGate = TimelinePlayheadDetailGate()
    // Photo clustering sorts the entire photo library. Keep that work out of
    // the playhead callback, which can arrive at 20 Hz while scrubbing.
    @State private var photoClusterCache = TimelinePhotoClusterCache()
    // Keep the playhead lookup on pre-filtered collections. Repeating-goal
    // expansion can make snapshot.plans large, and rebuilding those filters
    // on every 20 Hz callback needlessly competes with gesture rendering.
    @State private var selectionIndexCache = TimelineSelectionIndexCache()
    @State private var weatherContextCache = TimelineWeatherContextCache()
    @State private var showsAirQualityDetails = false
    @State private var detailPanelHeight: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            let defaultPanelHeight = geometry.size.height * 0.5
            let maxPanelHeight = max(
                detailPanelMinimumHeight,
                geometry.size.height - minimumTimelineBoardHeight
            )
            let resolvedPanelHeight = detailPanelHeight > 0
                ? min(detailPanelHeight, maxPanelHeight)
                : min(
                    max(defaultPanelHeight, detailPanelMinimumHeight),
                    maxPanelHeight
                )
            VStack(spacing: 0) {
                VStack(spacing: 0) {
            DraftTopBar(
                title: headerTitle,
                trailing: headerTrailing,
                selectedScale: model.selectedScale,
                scaleOptions: TimeScale.scheduleCases,
                onScaleChange: selectScaleFromTopBar,
                dayZoom: dayZoom,
                onDayZoomChange: { dayZoom = $0 },
                onTitleTap: { model.returnToNow() },
                onPrevious: { model.shiftSelectedDate(by: -1) },
                onNext: { model.shiftSelectedDate(by: 1) },
                onTrailingTap: closestWeather?.airQuality == nil
                    ? nil
                    : { showsAirQualityDetails = true },
                trailingAccessibilityLabel: AppLanguagePreference.text(
                    korean: "현재 날씨와 미세먼지 상세 보기",
                    english: "View current weather and air quality details"
                ),
                isPreviousEnabled: model.canShiftToPreviousPeriod,
                isNextEnabled: model.canShiftToNextPeriod
            )
            .simultaneousGesture(
                TapGesture().onEnded {
                    editingPlanID = nil
                }
            )
            if let missing = model.timelineIntegrationNotice {
                integrationNotice(missing)
            }
            if model.needsSleepConnectionNotice {
                sleepConnectionNotice
            }
            if let prompt = model.appleWatchOnboardingPrompt {
                appleWatchNotice(prompt)
            }
            TimelineBoard(
                model: model,
                scale: model.selectedScale,
                storedPlans: model.snapshot.plans,
                usesFullWidthRuler: resolvedPanelHeight >= maxPanelHeight - 1,
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
                    detailSection = selection.isRoute
                        ? .map
                        : selection.preferredDetailSection
                },
                onFocus: { selection in
                    playheadDetailGate.cancel()
                    mapPlayheadDate = nil
                    selectedTimelineItem = selection
                    selectedPhotoCluster = nil
                    detailSection = selection.isRoute
                        ? .map
                        : selection.preferredDetailSection
                },
                onPhotoSelection: { cluster in
                    playheadDetailGate.cancel()
                    editingPlanID = nil
                    mapPlayheadDate = nil
                    selectedPhotoCluster = cluster
                    selectedTimelineItem = .photo(cluster)
                    detailSection = .photo
                }
            )
            Spacer(minLength: 0)
                .contentShape(Rectangle())
                .onTapGesture {
                    editingPlanID = nil
                }
                }
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: .top
                )
            TimelineDetailPanel(
                model: model,
                selection: selectedTimelineItem,
                playheadDate: mapPlayheadDate,
                panelHeight: $detailPanelHeight,
                maxHeight: maxPanelHeight,
                section: $detailSection,
                highlightedSection: selectedTimelineItem?.preferredDetailSection,
                selectedPhotoCluster: $selectedPhotoCluster,
                routeReadings: model.mergingLiveSensorReadings(
                    routeReadings,
                    in: routeReadingsSpan
                ),
                onActualDeleted: { actualID in
                    if selectedTimelineItem?.actualID == actualID {
                        selectedTimelineItem = nil
                    }
                },
                onRouteSelection: { selection in
                    playheadDetailGate.cancel()
                    mapPlayheadDate = nil
                    selectedTimelineItem = selection
                    selectedPhotoCluster = nil
                    detailSection = .map
                }
            )
            .frame(height: resolvedPanelHeight, alignment: .top)
            .simultaneousGesture(
                TapGesture().onEnded {
                    editingPlanID = nil
                }
            )
            }
            .onAppear {
                if detailPanelHeight == 0 {
                    detailPanelHeight = defaultPanelHeight
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.tpBackground)
        .task(id: routeReadingsSpan) {
            routeReadings = await model.sensorReadings(in: routeReadingsSpan)
        }
        .task(id: model.timelineRevision) { // TPDEBUG
            guard ProcessInfo.processInfo.environment["TP_DEBUG_TRAVEL_INDEX"] != nil else { return }
            for step in 0..<24 {
                tpDebugSelectTravel()
                if step == 8 { detailSection = .weather }
                if step == 10 { detailSection = .map }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        .onChange(of: model.timelineRevision) { _, _ in
            refreshPlayheadDetailAfterTimelineReload()
        }
        .onDisappear {
            playheadDetailGate.cancel()
        }
        .sheet(isPresented: $showsAirQualityDetails) {
            if let weather = closestWeather,
               let airQuality = weather.airQuality {
                AirQualityDetailSheet(
                    weather: weather,
                    airQuality: airQuality
                )
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
            }
        }
    }

    // TPDEBUG
    private func tpDebugSelectTravel() {
        let environment = ProcessInfo.processInfo.environment
        guard let raw = environment["TP_DEBUG_TRAVEL_INDEX"] else { return }
        playheadDetailGate.cancel()
        if mapPlayheadDate != nil { mapPlayheadDate = nil }
        if selectedPhotoCluster != nil { selectedPhotoCluster = nil }
        let day = daySpan
        let todays = model.snapshot.travel
            .filter { $0.span.intersection(with: day) != nil }
            .sorted { $0.span.start < $1.span.start }
        guard let index = Int(raw), index >= 0, index < todays.count else {
            if selectedTimelineItem != nil { selectedTimelineItem = nil }
            return
        }
        let picked = todays[index]
        let wanted = TimelineSelection(
            title: "이동",
            span: picked.span,
            planID: nil,
            travelID: picked.id,
            recordNodeID: "automatic.travel.\(picked.id.uuidString)",
            isRoute: true,
            categoryID: "movement",
            categoryName: "이동"
        )
        if selectedTimelineItem != wanted { selectedTimelineItem = wanted }
    }

    private func selectScaleFromTopBar(_ scale: TimeScale) {
        model.selectScale(scale)
        dayZoom = TimelineZoomPreset.defaultPreset(for: scale)
    }

    private func integrationNotice(_ missing: [String]) -> some View {
        HStack(spacing: TaptionSpacing.regular) {
            Image(systemName: "exclamationmark.circle")
                .font(.taption(size: 13, weight: .bold))
                .foregroundStyle(Color.tpPlaceDark)
            VStack(alignment: .leading, spacing: 2) {
                Text("아직 자동으로 기록된 하루가 없습니다")
                    .font(.taption(size: 9.5, weight: .bold))
                    .foregroundStyle(Color.tpInk)
                Text("\(missing.joined(separator: " · ")) 연결이 꺼져 있어요")
                    .font(.taption(size: 7.5, weight: .semibold))
                    .foregroundStyle(Color.tpSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Button("설정 열기") {
                model.selectTab(.settings)
            }
            .font(.taption(size: 8, weight: .bold))
            .buttonStyle(.borderedProminent)
            .tint(Color.tpPlaceDark)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.tpPlace.opacity(0.22))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.tpPlaceDark.opacity(0.18)).frame(height: 0.5)
        }
    }

    private var sleepConnectionNotice: some View {
        HStack(spacing: TaptionSpacing.regular) {
            Image(systemName: "moon.zzz")
                .font(.taption(size: 13, weight: .bold))
                .foregroundStyle(Color.tpHealthDark)
            VStack(alignment: .leading, spacing: 2) {
                Text("오늘 수면 기록을 가져오지 못했습니다")
                    .font(.taption(size: 9.5, weight: .bold))
                    .foregroundStyle(Color.tpInk)
                Text("건강 앱의 수면 읽기 연결을 확인해 주세요")
                    .font(.taption(size: 7.5, weight: .semibold))
                    .foregroundStyle(Color.tpSecondary)
            }
            Spacer(minLength: 4)
            Button("수면 연결") {
                Task { await model.requestHealth() }
            }
            .font(.taption(size: 8, weight: .bold))
            .buttonStyle(.borderedProminent)
            .tint(Color.tpHealthDark)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.tpSuccessTint)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.tpHealthDark.opacity(0.18)).frame(height: 0.5)
        }
    }

    /// 첫 실행에 한 번 뜨는 Apple Watch 안내. 막아서지 않도록 시간표 위에
    /// 얹고, 닫으면 그 안내는 다시 오지 않는다.
    @ViewBuilder
    private func appleWatchNotice(
        _ prompt: AppleWatchOnboardingPrompt
    ) -> some View {
        VStack(alignment: .leading, spacing: TaptionSpacing.compact) {
            HStack(spacing: TaptionSpacing.regular) {
                Image(systemName: "applewatch")
                    .font(.taption(size: 13, weight: .bold))
                    .foregroundStyle(Color.tpInk)
                Text(
                    prompt == .installInvitation
                        ? "Apple Watch에도 BOKKI Plan이 있습니다"
                        : "Apple Watch 없이도 하루는 기록됩니다"
                )
                .font(.taption(size: 9.5, weight: .bold))
                .foregroundStyle(Color.tpInk)
                Spacer(minLength: 4)
                Button("닫기") {
                    model.dismissAppleWatchPrompt(prompt)
                }
                .font(.taption(size: 8, weight: .bold))
                .buttonStyle(.plain)
                .foregroundStyle(Color.tpSecondary)
            }
            switch prompt {
            case .installInvitation:
                Text("손목에 차고 있는 동안의 움직임까지 함께 적습니다. \(AppleWatchOnboarding.installInstruction)")
                    .font(.taption(size: 7.5, weight: .semibold))
                    .foregroundStyle(Color.tpSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .watchlessLimitations:
                VStack(alignment: .leading, spacing: 2) {
                    Text("Apple Watch가 있어야 되는 것만 적어 둡니다.")
                        .font(.taption(size: 7.5, weight: .semibold))
                        .foregroundStyle(Color.tpSecondary)
                    ForEach(
                        AppleWatchOnboarding.watchlessLimitations,
                        id: \.self
                    ) { limitation in
                        Text("· \(limitation)")
                            .font(.taption(size: 7.5))
                            .foregroundStyle(Color.tpSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(AppleWatchOnboarding.iPhoneOnlyCoverage)
                        .font(.taption(size: 7.5, weight: .semibold))
                        .foregroundStyle(Color.tpInk)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.tpBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.tpSecondary.opacity(0.18))
                .frame(height: 0.5)
        }
    }

    private func requestPlayheadDetailUpdate(at date: Date) {
        if ProcessInfo.processInfo.environment["TP_DEBUG_TRAVEL_INDEX"] != nil { return } // TPDEBUG
        playheadDetailGate.submit(
            date,
            minimumInterval: playheadDetailInterval(for: model.selectedScale)
        ) { deliveredDate in
            mapPlayheadDate = deliveredDate
            focusMapOnPlayhead(at: deliveredDate)
        }
    }

    private func refreshPlayheadDetailAfterTimelineReload() {
        // The board can render its first playhead before the async sensor/
        // calendar snapshot arrives. Re-run the same lookup once the data
        // revision changes, otherwise the panel remains in the empty state.
        let date = mapPlayheadDate
            ?? (selectedTimelineItem == nil ? model.selectedDate : nil)
        guard let date else { return }
        requestPlayheadDetailUpdate(at: date)
    }

    private func focusMapOnPlayhead(at date: Date) {
        guard let selection = timelineSelection(at: date) else {
            if selectedPhotoCluster != nil {
                selectedPhotoCluster = nil
            }
            // Keep the playhead date for map tracking, but do not invent a
            // focused goal/action when that instant has no timeline item.
            if selectedTimelineItem != nil {
                selectedTimelineItem = nil
            }
            if detailSection != .map {
                detailSection = .map
            }
            return
        }

        // A 20 Hz playhead tick usually remains inside the same item. Avoid
        // assigning an equal value back into @State, which would rebuild the
        // entire detail panel despite no visible selection change.
        if selectedTimelineItem != selection {
            selectedTimelineItem = selection
        }
        if selection.categoryID != "photo" {
            if selectedPhotoCluster != nil {
                selectedPhotoCluster = nil
            }
        }
    }

    private func timelineSelection(at date: Date) -> TimelineSelection? {
        let cluster = photoCluster(at: date)
        if let cluster, selectedPhotoCluster?.id != cluster.id {
            selectedPhotoCluster = cluster
        }
        return TimelineSelectionResolver.selection(
            at: date,
            model: model,
            cache: selectionIndexCache,
            photoCluster: cluster
        )
    }

    private func photoCluster(at date: Date) -> PhotoCluster? {
        let tolerance = photoPlayheadTolerance
        return photoClusterCache.nearest(
            timelineRevision: model.timelineRevision,
            photos: model.snapshot.photos,
            to: date,
            tolerance: tolerance
        )
    }

    private var photoPlayheadTolerance: TimeInterval {
        guard model.selectedScale == .day else { return 60 }
        return min(60, max(5, dayZoom.duration * 0.01))
    }

    private var headerTitle: String {
        ScheduleHeaderFormatter().playheadTitle(
            for: model.selectedDate,
            scale: model.selectedScale
        )
    }

    private var headerTrailing: String {
        switch model.selectedScale {
        case .day:
            if let weather = closestWeather {
                if let air = weather.airQuality {
                    "\(weather.temperatureCelsius.rounded().formatted())° · 미세 \(air.overallGrade.displayName) · \(weather.freshnessLabel)"
                } else {
                    "\(weather.temperatureCelsius.rounded().formatted())° · \(weather.condition) · \(weather.freshnessLabel)"
                }
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
        // 지도는 고른 구간만이 아니라 보고 있는 기간 전체의 경로를 깐다.
        // 좌표가 남아 있는 기간까지만 넓혀 읽는 양을 묶어 둔다.
        TimelineRouteDisplayPolicy.readingSpan(
            context: TimelineRouteDisplayPolicy.contextSpan(
                for: model.selectedScale.timelineLevel,
                visibleSpan: visibleSpan
            ),
            fallback: mapPlayheadDate != nil
                ? daySpan
                : (selectedTimelineItem?.span ?? daySpan)
        )
    }

    private var closestWeather: WeatherContext? {
        weatherContextCache.nearest(
            snapshotRevision: model.snapshotRevision,
            weather: model.snapshot.weather,
            inside: visibleSpan,
            to: model.selectedDate
        )
    }
}


#Preview {
    ScheduleView(model: AppModel())
}
