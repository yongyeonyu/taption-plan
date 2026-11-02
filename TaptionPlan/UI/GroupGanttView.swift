import SwiftUI
import UIKit
import MapKit

struct GroupGanttView: View {
    @Bindable var model: AppModel
    @State private var dayZoom: TimelineZoomPreset = .oneHour
    @State private var selectedTimelineItem: TimelineSelection?
    @State private var detailSection: TimelineDetailSection = .map
    @State private var selectedPhotoCluster: PhotoCluster?
    @State private var routeReadings: [SensorReading] = []
    @State private var editingPlanID: UUID?
    @State private var mapPlayheadDate: Date?
    @State private var playheadDetailGate = TimelinePlayheadDetailGate()
    @State private var photoClusterCache = TimelinePhotoClusterCache()
    @State private var selectionIndexCache = TimelineSelectionIndexCache()
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
                title: selectedGroup?.title ?? "그룹 간트",
                trailing: selectedGroup.map(periodText) ?? "",
                selectedScale: model.selectedScale,
                scaleOptions: TimeScale.scheduleCases,
                onScaleChange: selectScaleFromTopBar,
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
        .onChange(of: model.timelineRevision) { _, _ in
            refreshPlayheadDetailAfterTimelineReload()
        }
        .onDisappear {
            playheadDetailGate.cancel()
        }
    }

    private func selectScaleFromTopBar(_ scale: TimeScale) {
        model.selectScale(scale)
        dayZoom = TimelineZoomPreset.defaultPreset(for: scale)
    }

    private func requestPlayheadDetailUpdate(at date: Date) {
        playheadDetailGate.submit(
            date,
            minimumInterval: playheadDetailInterval(for: model.selectedScale)
        ) { deliveredDate in
            mapPlayheadDate = deliveredDate
            focusMapOnPlayhead(at: deliveredDate)
        }
    }

    private func refreshPlayheadDetailAfterTimelineReload() {
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
            if selectedTimelineItem != nil {
                selectedTimelineItem = nil
            }
            if detailSection != .map {
                detailSection = .map
            }
            return
        }

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
        TimelineRouteDisplayPolicy.readingSpan(
            context: TimelineRouteDisplayPolicy.contextSpan(
                for: model.selectedScale.timelineLevel,
                visibleSpan: TimelineAggregationEngine().interval(
                    for: model.selectedScale.timelineLevel,
                    containing: model.selectedDate
                )
            ),
            fallback: mapPlayheadDate != nil
                ? selectedDaySpan
                : (selectedTimelineItem?.span ?? selectedDaySpan)
        )
    }
}
