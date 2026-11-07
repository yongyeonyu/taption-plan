import Foundation

/// 본문이 읽지 않는 작업 핸들·세대 번호·시각(ARC1103A01 안 6).
/// 관찰하지 않는 참조라 값이 바뀌어도 지도 홈을 무효화하지 않고, 뷰 값도 작아진다.
/// 화면에 그리는 값은 여기에 두지 않는다.
@MainActor
final class MapHomeViewWork {
    var currentLocationRequestTask: Task<Void, Never>?
    var initialLocationRequestTask: Task<Void, Never>?
    var routeReadingsPreparationTask: Task<Void, Never>?
    var routeReadingsPreparationGeneration = MapHomeRouteReadingsPreparationGeneration()
    var mapSearchTask: Task<Void, Never>?
    var mapSearchRequestID = UUID()
    var transitPOIRefreshTask: Task<Void, Never>?
    var transitPOIRefreshGeneration: UInt64 = 0
    var lastTransitBoardingLiveRefreshAt: Date?
    var routeProjectionTask: Task<Void, Never>?
    var routeProjectionRunID = 0
    var routeProjectionApplied = 0
    var routeProjectionSkips = [0, 0, 0]
    var routeProjectionLastMS = 0.0
    var expectedRouteRefreshTask: Task<Void, Never>?
    var expectedRouteRefreshGeneration: UInt64 = 0
    var liveRouteProjectionRefreshTask: Task<Void, Never>?
    var playbackIntroTask: Task<Void, Never>?
    var dayPlaybackTask: Task<Void, Never>?
    var lastPlaybackTraceUptime: TimeInterval = 0
    var lastPlaybackRouteProjectionUptime: TimeInterval = 0
    var lastPlaybackMapFocusUptime: TimeInterval = 0
    var lastPlaybackFocusLogUptime: TimeInterval = 0
    var lastPlaybackMarkerUptime: TimeInterval = 0
    var lastTimelineMapFocusUptime: TimeInterval = 0
}

// 예전 `@State` 이름을 그대로 두어 호출하는 곳을 바꾸지 않는다.
extension MapHomeView {
    var currentLocationRequestTask: Task<Void, Never>? {
        get { work.currentLocationRequestTask }
        nonmutating set { work.currentLocationRequestTask = newValue }
    }
    var initialLocationRequestTask: Task<Void, Never>? {
        get { work.initialLocationRequestTask }
        nonmutating set { work.initialLocationRequestTask = newValue }
    }
    var routeReadingsPreparationTask: Task<Void, Never>? {
        get { work.routeReadingsPreparationTask }
        nonmutating set { work.routeReadingsPreparationTask = newValue }
    }
    var routeReadingsPreparationGeneration: MapHomeRouteReadingsPreparationGeneration {
        get { work.routeReadingsPreparationGeneration }
        nonmutating set { work.routeReadingsPreparationGeneration = newValue }
    }
    var mapSearchTask: Task<Void, Never>? {
        get { work.mapSearchTask }
        nonmutating set { work.mapSearchTask = newValue }
    }
    var mapSearchRequestID: UUID {
        get { work.mapSearchRequestID }
        nonmutating set { work.mapSearchRequestID = newValue }
    }
    var transitPOIRefreshTask: Task<Void, Never>? {
        get { work.transitPOIRefreshTask }
        nonmutating set { work.transitPOIRefreshTask = newValue }
    }
    var transitPOIRefreshGeneration: UInt64 {
        get { work.transitPOIRefreshGeneration }
        nonmutating set { work.transitPOIRefreshGeneration = newValue }
    }
    var lastTransitBoardingLiveRefreshAt: Date? {
        get { work.lastTransitBoardingLiveRefreshAt }
        nonmutating set { work.lastTransitBoardingLiveRefreshAt = newValue }
    }
    var routeProjectionTask: Task<Void, Never>? {
        get { work.routeProjectionTask }
        nonmutating set { work.routeProjectionTask = newValue }
    }
    var routeProjectionRunID: Int {
        get { work.routeProjectionRunID }
        nonmutating set { work.routeProjectionRunID = newValue }
    }
    var routeProjectionApplied: Int {
        get { work.routeProjectionApplied }
        nonmutating set { work.routeProjectionApplied = newValue }
    }
    var routeProjectionSkips: [Int] {
        get { work.routeProjectionSkips }
        nonmutating set { work.routeProjectionSkips = newValue }
    }
    var routeProjectionLastMS: Double {
        get { work.routeProjectionLastMS }
        nonmutating set { work.routeProjectionLastMS = newValue }
    }
    var expectedRouteRefreshTask: Task<Void, Never>? {
        get { work.expectedRouteRefreshTask }
        nonmutating set { work.expectedRouteRefreshTask = newValue }
    }
    var expectedRouteRefreshGeneration: UInt64 {
        get { work.expectedRouteRefreshGeneration }
        nonmutating set { work.expectedRouteRefreshGeneration = newValue }
    }
    var liveRouteProjectionRefreshTask: Task<Void, Never>? {
        get { work.liveRouteProjectionRefreshTask }
        nonmutating set { work.liveRouteProjectionRefreshTask = newValue }
    }
    var playbackIntroTask: Task<Void, Never>? {
        get { work.playbackIntroTask }
        nonmutating set { work.playbackIntroTask = newValue }
    }
    var dayPlaybackTask: Task<Void, Never>? {
        get { work.dayPlaybackTask }
        nonmutating set { work.dayPlaybackTask = newValue }
    }
    var lastPlaybackTraceUptime: TimeInterval {
        get { work.lastPlaybackTraceUptime }
        nonmutating set { work.lastPlaybackTraceUptime = newValue }
    }
    var lastPlaybackRouteProjectionUptime: TimeInterval {
        get { work.lastPlaybackRouteProjectionUptime }
        nonmutating set { work.lastPlaybackRouteProjectionUptime = newValue }
    }
    var lastPlaybackMapFocusUptime: TimeInterval {
        get { work.lastPlaybackMapFocusUptime }
        nonmutating set { work.lastPlaybackMapFocusUptime = newValue }
    }
    var lastPlaybackFocusLogUptime: TimeInterval {
        get { work.lastPlaybackFocusLogUptime }
        nonmutating set { work.lastPlaybackFocusLogUptime = newValue }
    }
    var lastPlaybackMarkerUptime: TimeInterval {
        get { work.lastPlaybackMarkerUptime }
        nonmutating set { work.lastPlaybackMarkerUptime = newValue }
    }
    var lastTimelineMapFocusUptime: TimeInterval {
        get { work.lastTimelineMapFocusUptime }
        nonmutating set { work.lastTimelineMapFocusUptime = newValue }
    }
}
