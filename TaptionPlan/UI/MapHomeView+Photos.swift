import CoreLocation
import MapKit
import Observation
import OSLog
import SwiftUI
import UIKit
import TaptionPlanCore

extension MapHomeView {
    func loadPhotoMoments(asksPermission: Bool) async {
        guard !FirstRunTutorialStore().defersPermissionPrompts else {
            photoMoments = []
            return
        }
        var state = photoLibrary.permissionState()
        if state == .notDetermined, asksPermission { state = await photoLibrary.requestAccess() }
        guard state == .authorized || state == .limited else {
            photoMoments = []
            return
        }
        let calendar = Calendar.autoupdatingCurrent
        let dayStart = calendar.startOfDay(for: model.selectedDate)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)
        let library = photoLibrary
        let readings = currentDayReadings
        let moments = await Task.detached(priority: .utility) {
            MapHomePhotoPolicy.placingUnlocated(
                library.moments(in: TimeSpan(start: dayStart, end: dayEnd)),
                readings: readings
            )
        }.value
        guard !Task.isCancelled else { return }
        // 위치를 끝내 못 구한 사진이 있으면 하루 데이터가 들어온 뒤 한 번 더 맞춘다.
        photosNeedReadingRetry = moments.contains { $0.location == nil }
        photoMoments = MapHomePhotoPolicy.locatedMoments(moments)
    }

    var photoClusters: [MapHomePhotoCluster] {
        // 재생 중 사진은 지도 대신 아래 사진 칸에 나온다.
        guard showsPhotosOnMap, !isDayPlaybackRunning, !photoMoments.isEmpty, recordingShows(\.photos) else { return [] }
        let radius = MapHomePhotoPolicy.clusterRadiusMeters(cameraDistance: visibleMapCamera?.distance)
        return photoClusterCache.clusters(for: photoMoments, radiusMeters: radius)
    }

    /// 핀에 보일 대표 사진·개수·강조 여부.
    func photoPinInfo(for cluster: MapHomePhotoCluster) -> (coverID: String, count: Int, highlighted: Bool)? {
        let highlighted = selectedTimelineMinute != nil
            && MapHomePhotoPolicy.isHighlighted(cluster, selectedMinute: Double(effectiveTimelineMinute))
        let cover = highlighted
            ? cluster.moments.min {
                abs(MapHomePhotoPolicy.minuteOfDay($0.capturedAt) - Double(effectiveTimelineMinute))
                    < abs(MapHomePhotoPolicy.minuteOfDay($1.capturedAt) - Double(effectiveTimelineMinute))
            } ?? cluster.moments[0]
            : cluster.moments[0]
        return (cover.id, cluster.count, highlighted)
    }

    func vectorPhotoMarkerID(_ id: String) -> String { "photo-\(id)" }

    /// 재생 중에는 화랑이를 피하지 않는다. 핀이 프레임마다 자리를 옮기게 된다.
    func photoPinPoint(_ cluster: MapHomePhotoCluster, in viewport: MapHomeVectorViewport?, places: [MapHomePlaceAnnotation]) -> CGPoint? {
        guard let pin = vectorPoint(in: viewport, for: vectorPhotoMarkerID(cluster.id)) else { return nil }
        var obstacles = places.compactMap { vectorPoint(in: viewport, for: vectorPlaceMarkerID($0.id)) }
            .map { MapHomePhotoPlacement.obstacle(center: $0, side: MapHomePlacePinLayout.avatarSize) }
        if !isDayPlaybackRunning, let cat = displayedCatViewportPoint {
            obstacles.append(MapHomePhotoPlacement.obstacle(center: cat, side: MapHomeCatTapRouting.hitRadius * 2))
            if counterWindowFrame.frame.width > 0 { obstacles.append(counterWindowFrame.frame) }
        }
        obstacles += mapMemosOnMap.compactMap { vectorPoint(in: viewport, for: vectorMapMemoMarkerID($0.id)) }
            .map { MapHomePhotoPlacement.obstacle(center: $0, side: 56) }
        return MapHomePhotoPlacement.point(for: pin, avoiding: obstacles)
    }

    @ViewBuilder
    var photoArcLayer: some View {
        let trailing = isSidebarVisible ? timeRailWidth + 12 : 12
        if isDayPlaybackRunning, recordingShows(\.photos), let minute = dayPlaybackCurrentMinute, !playbackPhotos.isEmpty {
            MapHomePlaybackPhotoStrip(minute: minute, photos: playbackPhotos).playbackPlacement(trailing: trailing)
        } else if let photoBrowserSelection, !isDayPlaybackRunning, !browsablePhotos.isEmpty {
            MapHomePhotoArcBrowser(
                moments: browsablePhotos,
                startID: photoBrowserSelection.startID,
                language: language,
                trailing: trailing
            ) { self.photoBrowserSelection = nil }
            .id(photoBrowserSelection.startID)
            .transition(.opacity)
        } else if showsPhotoRingTab {
            // 접히면 하단 메뉴 위 반달만 남는다(`bottomBar`가 그린다).
            EmptyView()
        } else if !isDayPlaybackRunning, !isScreenRecording, !isPhotoRingCovered, !browsablePhotos.isEmpty {
            let photos = browsablePhotos
            MapHomePhotoArcBrowser(
                moments: photos,
                startID: MapHomePhotoPolicy.nearest(photos, toMinute: Double(effectiveTimelineMinute))?.id,
                language: language,
                trailing: trailing,
                isRing: true,
                onPhotoChange: focusOnPhoto,
                onFold: { withAnimation(.easeInOut(duration: 0.25)) { isPhotoRingFolded = true } },
                onClose: {}
            )
            .id("\(model.selectedDate.timeIntervalSinceReferenceDate)|\(photos.count)")
        }
    }

    /// 사진링이 접혀 하단 메뉴 위에 반달이 붙어 있는지(BAR1108A01).
    var showsPhotoRingTab: Bool {
        photoBrowserSelection == nil && !isDayPlaybackRunning && !isScreenRecording && !isPhotoRingCovered
            && !browsablePhotos.isEmpty && isPhotoRingFolded
    }

    /// 링 밖 지도를 누르면 링을 `집` 단추 위 반달로 접는다(RNG1106A01, 대표 지시). 링 위 터치는 지도에 오지 않는다.
    func foldPhotoRingOnMapTap() {
        guard !isPhotoRingFolded, !isDayPlaybackRunning, !browsablePhotos.isEmpty else { return }
        withAnimation(.easeInOut(duration: 0.25)) { isPhotoRingFolded = true }
    }

    /// 메뉴·달력 같은 창이 떠 있으면 하단 링을 숨긴다(RNG1105A03).
    var isPhotoRingCovered: Bool {
        let panels = isMenuOpen || isCalendarPresented || isDaySummaryPresented || isDailyCardPresented
            || isSearchExpanded || todayCalendarExpanded
        let sheets = isRecordingOptionsPresented || isPlaybackVideoPresented || isCarAudioSheetPresented
            || isSalarySettingsPresented || isStrideCalibrationPresented || isTransitLocationsPresented
            || isSearchPinMenuPresented || isAlarmSettingsPresented || isMapAttributionPresented
            || isCalendarConnectPresented || isDataProtectionPresented || isCategoryAddPresented
            || isUnconfirmedReviewPresented || proAccess.isPurchaseSheetPresented
        let items = recordedVideoShare != nil || selectedMarkerInfo != nil || counterDetail != nil
            || selectedLocationDestination != nil || selectedUserLocation != nil || selectedMapStickerEditor != nil
            || selectedTransitBoardingCandidate != nil || selectedPredictedRoute != nil || pendingAlarm != nil
            || editingUserCategory != nil || sectionEditSelection != nil
        return panels || sheets || items
    }

    /// 링에서 고른 사진의 찍은 시각으로 사이드바를, 찍은 곳으로 지도를 옮긴다(RNG1105A01).
    func focusOnPhoto(_ photo: PhotoMoment) {
        selectedPawprintTimestamp = nil
        isTimelineSelectionPinned = true
        selectedTimelineMinute = min(1_439, max(0, Int(MapHomePhotoPolicy.minuteOfDay(photo.capturedAt))))
        if let location = photo.location { focusMap(on: location) }
    }

    /// 지도에서 넘겨 볼 그날 사진. 찍은 순서다.
    var browsablePhotos: [PhotoMoment] {
        photoMoments.filter { !$0.isHiddenFromTimeline }.sorted { $0.capturedAt < $1.capturedAt }
    }
}
