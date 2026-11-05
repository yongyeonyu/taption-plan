import CoreLocation
import MapKit
import Observation
import OSLog
import SwiftUI
import UIKit
import TaptionPlanCore

extension MapHomeView {
    func loadPhotoMoments(asksPermission: Bool) async {
        guard showsPhotosOnMap, !FirstRunTutorialStore().defersPermissionPrompts else {
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
        }
    }

    /// 지도에서 넘겨 볼 그날 사진. 찍은 순서다.
    var browsablePhotos: [PhotoMoment] {
        photoMoments.filter { !$0.isHiddenFromTimeline }.sorted { $0.capturedAt < $1.capturedAt }
    }
}
