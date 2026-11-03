import CoreLocation
import MapKit
import Observation
import OSLog
import SwiftUI
import UIKit
import TaptionPlanCore

@MainActor
struct MapHomeView: View {
    private static let dayViewSignpostLog = OSLog(
        subsystem: "com.taption.plan",
        category: .pointsOfInterest
    )
    @Environment(\.scenePhase) private var scenePhase
    @Bindable private var model: AppModel
    @Bindable private var proAccess: TaptionProAccessController
    private let onInitialDataReady: () -> Void

    @State private var mapPosition: MapCameraPosition = .automatic
    @State private var mapCameraRevision = 0
    @State private var appleViewportCommand: MapHomeAppleViewportCommand?
    @State private var vectorMapViewportStore = MapHomeVectorViewportStore()
    @State private var isMenuOpen = false
    @State private var isDateWeekExpanded = false
    @State private var isCalendarPresented = false
    @State private var selectedLocationDestination: MapHomeLocationDestination?
    @State private var isTransitLocationsPresented = false
    @State private var isLocationMenuExpanded = false
    @State private var isUserLocationsMenuExpanded = false
    @State private var isCategoryMenuExpanded = false
    @State private var isCategoryAddPresented = false
    @State private var isDisplayMenuExpanded = false
    @State private var isCounterMenuExpanded = false
    @State private var isSidebarGroupExpanded = false
    @State private var isMapGroupExpanded = false
    @AppStorage(MapHomeStickmanAction.vehicleDisplayKey) private var showsVehicleRides = true
    /// 화랑이 위 카운터 위젯이 지도 화면 좌표에서 차지하는 영역. 위젯을 누르면 카운터 메뉴를 연다(ARC1030A11).
    @State private var counterWindowFrame = MapHomeCounterFrameBox()
    /// 카운터 창 줄을 위에서 아래 순서로 늘어놓은 목록. 창을 눌렀을 때 몇 번째 줄인지 이 순서로 고른다.
    @State private var counterRowTargets: [MapHomeCounterDetailTarget] = []
    /// 지금 열려 있는 카운터 상세 화면.
    @State private var counterDetail: MapHomeCounterDetailTarget?
    /// 상세 화면은 연 순간의 값으로 만든다. 부모 본문이 다시 계산돼도 되풀이하지 않는다(SHT1102A01).
    @State private var counterDetailSnapshot = MapHomeCounterDetailSnapshot()
    /// 지도 뷰의 뷰포트 공간 프레임. 지도는 위 안전 영역까지 덮어 뷰포트보다 위에서 시작하므로(18 Pro Max에서 62pt), 지도 안 점과 뷰포트 탭을 이 원점으로 맞춘다.
    @State private var mapFrameInViewport = CGRect.zero
    @State private var isStrideCalibrationPresented = false
    @State private var isSalarySettingsPresented = false
    @State private var isCarAudioSheetPresented = false
    @AppStorage(MapHomeSalaryPolicy.annualKey) private var salaryAnnualPay = 0.0
    @AppStorage(MapHomeSalaryPolicy.monthlyPayKey) private var salaryMonthlyPay = 0.0
    @AppStorage(MapHomeSalaryPolicy.isNetInputKey) private var salaryIsNetInput = false
    @AppStorage(MapHomeSalaryPolicy.showsNetKey) private var salaryShowsNet = true
    @AppStorage(MapHomeSalaryPolicy.monthAccumKey) private var salaryMonthAccum = 0.0
    @AppStorage(MapHomeSalaryPolicy.payHistoryKey) private var salaryPayHistoryRaw = ""
    @AppStorage(MapHomeSalaryPolicy.tickKey) private var salaryTickSeconds = 10
    @State private var salaryLive: MapHomeSalaryPolicy.Live?
    /// 날짜(0시)별 업무 구간. 선택한 날짜와 오늘만 둔다.
    @State private var salaryWorkSpans: [Date: [TimeSpan]] = [:]
    @State private var queueExpanded = false
    @State private var memoStackExpanded = false
    @State private var todayCalendarExpanded = false
    @State private var topPanelOrder: [TopPanel] = []
    /// 선택한 날의 일정(구글 계정 연결 시 구글, 아니면 기기 캘린더). 시작 시간에 구글 로고로 표시한다.
    @State private var dayCalendarEvents: [CalendarRecord] = []
    /// `dayCalendarEvents`가 어느 날짜의 목록인지. 날짜를 바꾼 직후 이전 날 목록이 남지 않게 한다.
    @State private var dayCalendarEventsDate: Date?
    /// 오른쪽 사이드바(시간·날씨 띠) 전체를 켜고 끈다. 날짜 배지 아래 원형 버튼으로 바꾼다.
    @AppStorage("mapHomeSidebarVisible") private var isSidebarVisible = true
    /// 일정을 읽지 못한 이유. 있으면 구글 캘린더 버튼이 목록 대신 고칠 수 있는 설정을 연다.
    @State private var calendarAccessProblem: MapHomeCalendarAccessProblem?
    /// 선택한 날의 시간 메모 캐시(배지 계산용).
    @State private var timedMemoCache: [ActionMemo] = []
    /// 날짜 줄을 끄는 동안 손가락을 따라 움직이는 거리(한 칸을 넘지 않는다).
    /// 시작 시간 제한이 지났는지(DB나 경로가 끝나지 않아도 홈을 연다).
    @State private var initialReadyForced = false
    @State private var calendarService = AppleCalendarService()
    @State private var isHomeMissingAlertPresented = false
    @State private var isPlacingMapMemo = false
    @State private var dismissedMemoPreviewIDs = Set<UUID>()
    private let isStickerMode = true
    @State private var selectedMapStickerEditor: MapHomeStickerEditorTarget?
    @State private var sidebarNote: MapHomeSidebarNote?
    @State private var isAppleWatchMenuExpanded = false
    @State private var isSettingsMenuExpanded = false
    @State private var isGPSLoggingMenuExpanded = false
    @State private var isDataProtectionPresented = false
    @State private var isSettingsResetConfirmationPresented = false
    @AppStorage(
        AppLanguagePreference.sharedDefaultsKey,
        store: UserDefaults(suiteName: AppLanguagePreference.appGroupIdentifier)
    ) private var languageRawValue = AppLanguagePreference.current.rawValue
    @AppStorage(MapHomePlaybackZoomMode.storageKey)
    private var playbackZoomModeRaw = MapHomePlaybackZoomMode.adaptive.rawValue
    @AppStorage(MapHomeLayoutStyle.storageKey)
    private var layoutStyleRaw = MapHomeLayoutStyle.classic.rawValue
    @AppStorage(MapHomeRecordingLayers.storageKey)
    private var recordingLayersRaw = ""
    @State private var isScreenRecording = false
    @State private var photoMoments: [PhotoMoment] = []
    @State private var photosNeedReadingRetry = false
    @AppStorage("mapHomeShowsPhotos") private var showsPhotosOnMap = true
    /// 표시 메뉴의 경로·발자국 켜기/끄기(대표 지시, ARC1030A06). 녹화 레이어와는 별개로, 평소 화면에 적용된다.
    @AppStorage("mapHomeShowsRoutes") private var showsRoutesOnMap = true
    @AppStorage("mapHomeShowsFootprints") private var showsFootprintsOnMap = true
    @AppStorage(MapHomeSidebarTimeFormat.storageKey) private var sidebarTimeFormatRaw = MapHomeSidebarTimeFormat.twentyFourHour.rawValue
    @AppStorage(MapHomeSidebarRulerInterval.storageKey) private var sidebarRulerIntervalRaw = MapHomeSidebarRulerInterval.automatic.rawValue
    @AppStorage("mapHomeMemoDisplay") private var memoDisplayRaw = MapHomeMemoDisplayMode.all.rawValue
    // 표시 > 카운터에서 켜고 끄는 카운터. 연봉 카운터만 따로 설정 화면을 갖는다.
    @AppStorage(MapHomeCounterKind.steps.storageKey) private var showsStepCounter = true
    @AppStorage(MapHomeCounterKind.distance.storageKey) private var showsDistanceCounter = true
    @AppStorage(MapHomeCounterKind.work.storageKey) private var showsWorkCounter = true
    @AppStorage(MapHomeCounterKind.study.storageKey) private var showsStudyCounter = true
    @AppStorage(MapHomeCounterKind.hobby.storageKey) private var showsHobbyCounter = true
    @AppStorage(MapHomeCounterKind.exercise.storageKey) private var showsExerciseCounter = true
    @AppStorage("mapHomeCounter.salary") private var showsSalaryCounter = true
    @AppStorage("mapHomeCounter.collapsed") private var isCounterCollapsed = false
    @State private var isCalendarConnectPresented = false
    @State private var pendingMemoLocationID: UUID?
    @State private var isMapAttributionPresented = false
    @State private var isAlarmSettingsPresented = false
    @State private var pendingAlarm: (kind: MapHomeAlarmKind, at: Date)?
    @AppStorage("appleWatchLinkEnabled") private var isAppleWatchLinkEnabled = true
    @State private var isDailyCardPresented = false
    /// 땅은 벡터 지도에서만 그려져서, 붙일 타일이 있고 집 근처로 확대하면 벡터 스타일로 자동 전환했다가 끝나면 되돌린다.
    @AppStorage("mapHomeAutoLandStyle") private var autoLandStyleEnabled = true
    /// "원래 스타일|자동 전환한 스타일". 비어 있으면 자동 전환 중이 아니다.
    @AppStorage("mapHomeAutoLandStyleState") private var autoLandStyleState = ""
    @State private var photoClusterCache = MapHomePhotoClusterCache()
    @State private var photoAlbumSelection: MapHomePhotoAlbumSelection?
    private let photoLibrary = ApplePhotoLibraryService()
    @State private var isRecordingOptionsPresented = false
    @State private var isPlaybackVideoPresented = false
    @State private var recordedVideoShare: URL?
    @State private var recordingFailureMessage: String?

    @State private var screenRecorder = MapHomeScreenRecorder()
    @AppStorage(MapHomeGrowthPolicy.storageKey)
    private var homeGrowthData = Data()
    @State private var growthHistoryCache = MapHomeGrowthHistoryCache()
    @State private var compassControlState: MapHomeCompassControlState = .directionArrow
    @State private var headingMonitor = MapHomeHeadingMonitor()
    @State private var selectedScope: TimeScale = .day
    @State private var playbackProgress = MapHomePlaybackProgress()
    /// 선택한 분. 값은 관찰 저장소에 있어, 읽는 화면 조각만 다시 그려진다(ARC1030A01).
    private var selectedTimelineMinute: Int? {
        get {
            if MapHomeMinuteFreeze.isFrozen { return playbackProgress.rawSelectedMinute }
            MapHomePlaybackProbe.noteMinuteRead()
            return playbackProgress.selectedMinute
        }
        nonmutating set {
            playbackProgress.rawSelectedMinute = newValue
            playbackProgress.selectedMinute = newValue
        }
    }
    @State private var selectedPawprintTimestamp: Date?
    /// 발자국을 누르면 강조하는 발자국의 시각. 재생·시간 조정으로 지워지는 선택과 따로 둔다.
    @State private var highlightedPawprintTimestamp: Date?
    @State private var selectedPawprintCoordinate: CLLocationCoordinate2D?
    @State private var isTimelineSelectionPinned = false
    @State private var sectionEditSelection: MapHomeSectionEditSelection?
    @State private var isUnconfirmedReviewPresented = false
    @State private var focusedUnconfirmedReviewSegment: MapHomeTimeRailSegment?
    @State private var pendingUnconfirmedEditMinute: Int?
    @State private var isMapCenteredOnUser = false
    @SceneStorage("MapHome.userTrackingMode")
    private var userTrackingModeRawValue = MapHomeUserTrackingMode.idle.rawValue
    @State private var currentLocationRequestTask: Task<Void, Never>?
    @State private var initialLocationRequestTask: Task<Void, Never>?
    @State private var routeReadingsPreparationTask: Task<Void, Never>?
    @State private var routeReadingsPreparationGeneration =
        MapHomeRouteReadingsPreparationGeneration()
    @State private var hasAppliedInitialLocation = false
    @State private var hasAppliedInitialMapFocus = false
    @State private var startupCameraPolicy = MapHomeStartupCameraPolicy()
    @State private var hasCancelledInitialLocationFocus = false
    @State private var mapSearchText = ""
    @State private var mapSearchResults: [MapHomeSearchResult] = []
    @State private var selectedSearchPin: MapHomeSearchResult?
    @State private var isSearchPinMenuPresented = false
    @State private var selectedMarkerInfo: MapHomeMarkerInfoKind?
    /// 랜드마크 시트가 등록지점(집·회사·식당 등)을 고칠 수 있도록 누른 장소 id를 함께 든다.
    @State private var selectedMarkerPlaceID: UUID?
    /// 등록 위치의 범위(주황·빨강 원) 표시 여부. 랜드마크 시트에서 켜고 끈다.
    @AppStorage(MapHomePlaceRangeEditor.showsRangeKey) private var showsPlaceRanges = true
    /// 안개 탐험 강도. 앱을 다시 열어도 고른 세기가 남는다.
    @AppStorage(MapHomeFogStrength.storageKey) private var fogStrengthRaw = MapHomeFogStrength.light.rawValue
    @State private var isLongPressMenuPresented = false
    @State private var isDaySummaryPresented = false
    /// 하루 요약을 화랑이에서 열었는지. 열려 있는 동안 카메라 맞춤의 기준이 집 대신 화랑이가 된다.
    @State private var daySummaryFocusesCat = false
    /// 하루요약 시트 높이. 접으면 화면 절반, 위로 펼치면 지금의 전체 화면이다.
    @State private var daySummaryDetent: PresentationDetent = MapHomeDaySummarySheet.collapsedDetent
    /// 지도 카메라에 이미 반영한 "시트가 덮은 비율". 0이면 지도 전체가 보이는 상태다.
    @State private var daySummaryAppliedCoverage: CGFloat = 0
    @State private var pendingLongPressCoordinate: CLLocationCoordinate2D?
    @State private var requestingPermission: RequiredPermission?
    @State private var selectedUserLocation: MapHomeUserLocationSelection?
    @State private var selectedTransitBoardingCandidate: TransitBoardingCandidate?
    @State private var selectedPredictedRoute: MapPredictedRoute?
    @State private var pendingUserLocationSelection: MapHomeUserLocationSelection?
    @State private var mapSearchTask: Task<Void, Never>?
    @State private var transitPOIRefreshTask: Task<Void, Never>?
    @State private var transitPOIRefreshGeneration: UInt64 = 0
    @State private var nearbyTransitPlaces: [TransitBoardingPlace] = []
    @State private var transitBoardingReadingsRevision: UInt64 = 0
    @State private var lastTransitBoardingLiveRefreshAt: Date?
    @State private var nearbyTransitPlacesRevision: UInt64 = 0
    @State private var mapSearchCompleter = MapHomeSearchCompleter()
    @State private var mapSearchRequestID = UUID()
    @FocusState private var isMapSearchFocused: Bool
    @State private var isSearchExpanded = false
    @State private var visibleMapCenter = CLLocationCoordinate2D(latitude: 0, longitude: 0)
    @State private var timeRailSegments: [MapHomeTimeRailSegment] = []
    @State private var routeProjection: RouteTimelineProjection?
    /// 마지막 경로 계산의 입력 요약. 같으면 다시 계산하지 않는다.
    @State private var routeProjectionInputKey: RouteProjectionInputKey?
    @State private var routeProjectionTask: Task<Void, Never>?
    @State private var routeProjectionRunID = 0
    /// 발자국 장부 캐시. 기록이 늘 때만 새로 만든다(ARC1030A07).
    @State private var pawprintLedgerMemo = MapHomeMemo<MapHomePawprintLedgerKey, [MapHomePawprintLedger.Entry]>()
    @State private var pawprintWaypointsMemo = MapHomeMemo<MapHomePawprintWaypointsKey, [PawprintWaypoint]>()
    @State private var routeProjectionApplied = 0
    @State private var routeProjectionSkips = [0, 0, 0]
    @State private var routeProjectionLastMS = 0.0
    @State private var lastPlaybackTraceUptime: TimeInterval = 0
    @State private var routeProjectionInFlight = false
    @State private var routeProjectionDirty = false
    @State private var routeActualIndex: RouteTimelineDataEngine.ActualIndex?
    @State private var wbsPlaybackProjection: MapHomeWBSPlaybackProjection?
    @State private var dayDataSnapshot: PlanDayDataSnapshot?
    @State private var dayDataIsPreview = false
    @State private var hasDeferredWBSPlaybackRefresh = false
    @State private var routeReadings: [SensorReading] = []
    @State private var routeReadingsLoadState: MapHomeRouteReadingsLoadState = .idle
    @State private var hasReportedInitialDataReady = false
    @State private var normalizedRouteReadings: [SensorReading] = []
    @State private var currentMapLocationReading: SensorReading?
    @State private var historicalPlaybackReadings: [SensorReading] = []
    @State private var displayRouteReadings: [SensorReading] = []
    @State private var lastPreparedRouteReadingsSignature: String?
    @State private var timelineRouteOverlays: [MapHomeTimelineRouteOverlay] = []
    @State private var cachedTemporaryLocations: [SubwayStationCatalog.TemporaryLocation] = []
    @State private var expectedRouteOverlays: [MapHomeExpectedRouteOverlay] = []
    @State private var wbsGeneratedRouteOverlays: [MapHomeWBSGeneratedRouteOverlay] = []
    @State private var pendingForecastRouteState: MapHomeForecastRouteState?
    @State private var expectedRouteCache: [ExpectedRouteRequest: [CLLocationCoordinate2D]] = [:]
    @State private var expectedRouteRefreshTask: Task<Void, Never>?
    @State private var expectedRouteRefreshGeneration: UInt64 = 0
    @State private var wbsExpectedRouteRequests: [ExpectedRouteRequest] = []
    @State private var wbsExpectedRouteRequestsInputKey: MapHomeExpectedRouteInputKey?
    @State private var liveRouteProjectionRefreshTask: Task<Void, Never>?
    @State private var visibleMapSpan = MKCoordinateSpan(
        latitudeDelta: 0.025,
        longitudeDelta: 0.035
    )
    @State private var sharedZoomLevel: CGFloat = 1
    @State private var zoomResetToken = 0
    /// 시간선 확대·축소 단추가 올리는 값. 레일은 이 값의 변화량만큼 단계를 밟는다.
    @State private var zoomStepToken = 0
    /// 시간선이 보이는 창(시작 분·길이). 시간 레일·날씨 띠·선택 캡슐이 이 값 하나를
    /// 함께 쓴다. 두 벌로 두면 한쪽만 되돌아가 두 시간축이 어긋난다(2026-10-27).
    @State private var timeSidebarVisibleStartMinute = 0
    @State private var timeSidebarVisibleDurationMinutes = MapHomeTimeSidebarMath.fullDayMinutes
    @State private var cachedWeatherContexts: [WeatherContext]
    @State private var activePaletteCategoryID: String?
    @State private var customPaletteColor = Color.tpReferenceMint
    @State private var mapCameraFrameProjection = MapHomeCameraFrameProjection()
    @State private var mapRenderCache = MapHomeMapRenderCache()
    @State private var liveZoomGovernor = MapHomeLiveZoomGovernor()
    @State private var playbackZoomSmoother = MapHomePlaybackZoomSmoother()
    @State private var playbackZoomPlan = MapHomePlaybackZoomPlan(inputs: [])
    @State private var visibleMapCamera: MapCamera?
    @State private var shouldFitRoutesAfterDateChange = false
    @State private var hasUserAdjustedMap = false
    @State private var stickmanViewportProjection = MapHomeStickmanViewportProjection()
    @State private var displayedStickmanViewportPoint: CGPoint?
    /// Apple 지도가 움직이는 동안 프레임마다 받은 화랑이 점(관찰 안 함)과 "움직이는 중" 표시.
    /// 카운터 창은 움직이는 동안 이 상자를 화면 틱마다 읽고, 관찰 값은 읽기 값 간격과 손을 뗄 때만 따라온다(UIX1031A06).
    @State private var appleStickmanLivePoint = MapHomeAppleStickmanLivePoint()
    @State private var isAppleCameraMoving = false
    @State private var mapViewportSize = CGSize.zero
    @State private var headerFrame = CGRect.zero
    @State private var searchFieldFrame = CGRect.zero
    @State private var mapControlsFrame = CGRect.zero
    @State private var isDayPlaybackRunning = false
    private var dayPlaybackCurrentMinute: Double? {
        get {
            if MapHomeMinuteFreeze.isFrozen { return playbackProgress.rawCurrentMinute }
            MapHomePlaybackProbe.noteMinuteRead()
            return playbackProgress.currentMinute
        }
        nonmutating set {
            playbackProgress.rawCurrentMinute = newValue
            playbackProgress.currentMinute = newValue
        }
    }
    @State private var counterValueCache = MapHomeCounterValueCache()
    @State private var counterBadgeThrottle = MapHomeCounterBadgeThrottle()
    @State private var isTimelineInteractionActive = false
    @State private var routeDocumentProjectionGate = MapHomeRouteDocumentProjectionGate()
    @State private var lastPlaybackRouteProjectionUptime: TimeInterval = 0
    @State private var lastPlaybackMapFocusUptime: TimeInterval = 0
    @State private var isPlaybackIntroActive = false
    @State private var playbackIntroTask: Task<Void, Never>?
    @State private var lastPlaybackFocusLogUptime: TimeInterval = 0
    @State private var lastPlaybackMarkerUptime: TimeInterval = 0
    @State private var lastTimelineMapFocusUptime: TimeInterval = 0
    @State private var dayPlaybackTask: Task<Void, Never>?
    @State private var playbackClock = MapHomePlaybackClock()
    @State private var dayReadingsCache = MapHomeDayReadingsCache()
    @State private var temporaryLocationsMemo = MapHomeMemo<MapHomeReadingsSignature, [SubwayStationCatalog.TemporaryLocation]>()
    @State private var predictedGapsMemo = MapHomeMemo<MapHomeReadingsSignature, [MapHomePredictedGPSGap]>()
    @State private var subwayOverlayDerived = MapHomeStaleWhileRevalidate<MapHomeReadingsSignature, Int, [MapHomeSubwayRouteOverlay]>()
    @State private var derivedUpdateTick = 0
    @State private var homeWeatherBadgeMemo = MapHomeMemo<MapHomeHomeWeatherKey, MapHomeHomeWeatherBadge?>()
    @State private var stickmanActionMemo = MapHomeMemo<MapHomeStickmanActionKey, MapHomeStickmanAction>()
    @State private var transitBoardingDerived = MapHomeStaleWhileRevalidate<MapHomeTransitBoardingGroup, Date, [TransitBoardingCandidate]>()
    @State private var transitBoardingReadingsMemo = MapHomeMemo<MapHomeReadingsSignature, [SensorReading]>()
    /// 벡터 지도에서는 재생을 구동기가 맡는다(PLY1029A03). Apple 지도는 아직 예전 루프.
    @State private var playbackDriver: MapHomePlaybackDriver?
    @State private var mapDayCacheWriteSignature: Int?

    private static let categoryPaletteHexes = [
        "#8FD9C5", "#A9CFF0", "#A7DDEB", "#C2B4E9",
        "#B8B7E8", "#F2B18D", "#F2A8B8", "#CBD5E1",
        "#F2D58D", "#F28FA9", "#B7DCC7", "#B7D5EE",
    ]

    private static let mapCacheAlgorithmKey = "route-document-v10"

    private enum Layout {
        static let horizontalInset: CGFloat = 10
        /// 상단 한 줄의 공통 높이(메모·일정 원형 버튼, 날짜 줄, 날짜 배지).
        static let dateBadgeSize: CGFloat = 40
        /// 상단 한 줄의 위 여백. 메뉴·메모·일정·날짜 배지가 모두 이 값만큼
        /// 내려온 같은 높이에 놓인다(가운데 높이 = topRowInset + dateBadgeSize/2).
        static let topRowInset: CGFloat = 12
        static let headerVisibleHeight: CGFloat = 46
        static let headerHitTarget: CGFloat = 44
        static let headerIcon: CGFloat = 19
        static let mapControlSize = MapHomeOverlayLayoutMath.controlSize
        static let mapControlIcon: CGFloat = 15
        static let mapControlSpacing = MapHomeOverlayLayoutMath.controlSpacing
        static let weatherRailWidth: CGFloat = 62
        static let timeRailTopMargin: CGFloat = 46
        static let topOverlayFallbackHeight: CGFloat = 104
        static let overlayBottomMargin = MapHomeOverlayLayoutMath.sharedBottomMargin
        static let menuMinimumWidth: CGFloat = 260
        static let menuMaximumWidth: CGFloat = 300

        static func menuWidth(for viewportWidth: CGFloat) -> CGFloat {
            min(max(viewportWidth * 0.72, menuMinimumWidth), menuMaximumWidth)
        }
    }

    init(
        model: AppModel,
        proAccess: TaptionProAccessController,
        onInitialDataReady: @escaping () -> Void = {}
    ) {
        self._model = Bindable(model)
        self._proAccess = Bindable(proAccess)
        self.onInitialDataReady = onInitialDataReady
        _selectedScope = State(initialValue: .day)
        _timeRailSegments = State(initialValue: [])
        let storedWeather: [WeatherContext] = model.snapshot.weather
        var completeWeather: [WeatherContext] = []
        for context in storedWeather where MapHomeWeatherDisplayPolicy.isComplete(context) {
            completeWeather.append(context)
        }
        let displayWeather: [WeatherContext] = MapHomeWeatherTimelineMath.coalescedDisplayContexts(completeWeather)
        _cachedWeatherContexts = State(initialValue: displayWeather)
    }

    private var language: MapHomeLanguage {
        switch AppLanguagePreference.resolve(rawValue: languageRawValue) {
        case .korean: .korean
        case .english: .english
        }
    }

    private var languagePreference: AppLanguagePreference {
        AppLanguagePreference(rawValue: languageRawValue) ?? .automatic
    }

    private var userTrackingMode: MapHomeUserTrackingMode {
        MapHomeUserTrackingMode(rawValue: userTrackingModeRawValue) ?? .idle
    }

    /// 지금 하루요약 시트가 지도를 덮고 있는 비율. 펼치면 지도가 다 가려져 보정하지 않는다.
    private var daySummaryCoverage: CGFloat {
        guard isDaySummaryPresented, !isWideLayout,
              daySummaryDetent != MapHomeDaySummarySheet.expandedDetent
        else { return 0 }
        return MapHomeDaySummaryLayout.collapsedCoverage
    }

    private var isWideLayout: Bool { MapHomeWideLayoutPolicy.isWide(viewportWidth: mapViewportSize.width) }
    private var timeRailWidth: CGFloat { MapHomeWideLayoutPolicy.timeRailWidth(viewportWidth: mapViewportSize.width) }

    /// 왼쪽 패널이 열려 있으면 지도를 그만큼 줄여 가리지 않는다.
    private var mapLeadingInset: CGFloat {
        let panel: MapHomeWidePanelKind? = isCalendarPresented ? .calendar : isMenuOpen ? menuPanelKind
            : isDaySummaryPresented || isDailyCardPresented ? .standard : nil
        return MapHomeWideLayoutPolicy.mapLeadingInset(viewportWidth: mapViewportSize.width, openPanel: panel)
    }

    private var menuPanelKind: MapHomeWidePanelKind {
        MapHomeWideLayoutPolicy.menuPanelKind(viewportSize: mapViewportSize, hasPermissionCard: !sensorCollectionPermissionGate.sensorCollectionReady)
    }

    private var isHeadingMode: Bool {
        compassControlState == .compass
    }

    private var compassRotationDegrees: Double {
        headingMonitor.rotationDegrees
            ?? MapHomeCompassControlState.iconRotationDegrees(
                for: model.latestSensorReading?.courseDegrees ?? 0
            )
    }

    private var sidebarInteractionWidth: CGFloat {
        MapHomeTimeSidebarMath.totalWidth(railWidth: timeRailWidth)
            + Layout.horizontalInset
    }

    private var mapSearchWidth: CGFloat {
        MapHomeSearchLayoutMath.searchWidth(
            viewportWidth: MapHomeWideLayoutPolicy.searchViewportWidth(mapViewportSize.width > 0 ? mapViewportSize.width : UIScreen.main.bounds.width),
            horizontalInset: Layout.horizontalInset,
            trailingControlCount: 1
        )
    }

    private var isMapSearchOverlayPresented: Bool {
        isMapSearchFocused
            || hasMapSearchResults
    }

    /// 검색 오버레이가 실제로 열려 있어 지도 탭으로 닫아야 하는 상태.
    /// 이게 아닐 때는 지도에 탭 제스처를 붙이지 않아 지도 팬·핀치와 경합하지 않는다.
    private var isSearchDismissable: Bool {
        isSearchExpanded
            || isMapSearchFocused
            || hasMapSearchResults
            || !mapSearchText.isEmpty
            || selectedSearchPin != nil
    }

    private var hasMapSearchResults: Bool {
        !mapSearchResults.isEmpty || !mapSearchCompleter.results.isEmpty
    }

    private var mapSearchResultCount: Int {
        mapSearchResults.isEmpty
            ? mapSearchCompleter.results.count
            : mapSearchResults.count
    }

    private var mapSearchSurfaceHeight: CGFloat {
        guard hasMapSearchResults else { return 42 }
        return 42 + 5 + MapHomeSearchLayoutMath.searchResultsHeight(
            resultCount: mapSearchResultCount
        )
    }

    /// 지도에서 "가운데"로 삼을 점. 하루요약 시트가 아래를 덮으면 가려지지 않은 영역의 가운데다.
    private var currentLocationTargetPoint: CGPoint {
        MapHomeDaySummaryLayout.targetPoint(
            viewportSize: mapViewportSize,
            coverage: daySummaryCoverage
        ).applying(CGAffineTransform(translationX: mapLeadingInset / 2, y: 0))
    }

    private var topOverlayHeight: CGFloat {
        MapHomeOverlayLayoutMath.topOverlayHeight(
            headerFrame: headerFrame,
            searchFrame: searchFieldFrame,
            fallback: Layout.topOverlayFallbackHeight
        )
    }

    /// 행동구간 편집에 들어갈 때 바로 여는 클립 편집기. 저장하면 고른 구간을
    /// 그대로 선택해 두고, 미확인 구간을 고쳤으면 그날 보상을 준다.
    private func clipEditorSheet(
        for selection: MapHomeSectionEditSelection
    ) -> some View {
        MapHomeNLEClipEditor(
            model: model,
            language: language,
            date: selection.date,
            segments: selection.daySegments.isEmpty
                ? [selection.segment]
                : selection.daySegments,
            details: selection.dayDetails.isEmpty
                ? selection.details
                : selection.dayDetails,
            focusMinute: selection.segment.startMinute,
            onSaved: {
                applySectionEditSave(
                    selection.selectedSpan,
                    selection: selection
                )
            }
        )
    }

    /// 구간 편집을 저장한 뒤 선택 시각을 그 구간 가운데로 되돌린다.
    /// 클립 편집기와 (지금은 숨긴) 행동구간 편집 화면이 같은 규칙을 쓴다.
    private func applySectionEditSave(
        _ span: TimeSpan,
        selection: MapHomeSectionEditSelection
    ) {
        refreshTimeRailSegments()
        let calendar = Calendar.autoupdatingCurrent
        let dayStart = calendar.startOfDay(for: selection.date)
        let midpoint = span.start.addingTimeInterval(span.duration / 2)
        selectedTimelineMinute = min(
            1_439,
            max(0, Int(midpoint.timeIntervalSince(dayStart) / 60))
        )
        isTimelineSelectionPinned = true
        if selection.segment.categoryID == "unconfirmed" {
            rewardRecentCompletedDay(selection.date)
        }
    }

    /// 지금은 쓰지 않는 행동구간 편집 화면. 클립 편집기로 대체되어 호출부가
    /// 주석 처리되어 있다. 화면을 되돌릴 때 이 함수를 다시 연결한다.
    private func sectionEditSheet(for selection: MapHomeSectionEditSelection) -> some View {
        MapHomeSectionEditSheet(
            model: model,
            selection: selection,
            language: language,
            onSaved: { result in
                applySectionEditSave(
                    result.selectedSpan,
                    selection: selection
                )
            }
        )
    }

    private func quickConfirmUnconfirmed(
        _ segment: MapHomeTimeRailSegment,
        as category: MapHomeSidebarMajorCategory
    ) async -> Bool {
        guard model.isBootstrapped else { return false }
        let calendar = Calendar.autoupdatingCurrent
        let selectedDay = model.selectedDate
        let startOfDay = calendar.startOfDay(for: selectedDay)
        guard segment.categoryID == "unconfirmed",
              segment.startMinute < segment.endMinute,
              let start = calendar.date(byAdding: .minute, value: segment.startMinute, to: startOfDay),
              let end = calendar.date(byAdding: .minute, value: segment.endMinute, to: startOfDay)
        else { return false }
        let original = ActivityCorrectionOption(
            id: "phase.unconfirmed",
            title: segment.title,
            behavior: segment.behavior,
            categoryID: "unconfirmed",
            systemImage: "questionmark",
            isAutomatic: false,
            isCustom: false
        )
        let choice = ActivityCorrectionOption(
            id: "phase.\(category.id)",
            title: category.title,
            behavior: nil,
            categoryID: category.id,
            systemImage: category.systemImage,
            isAutomatic: false,
            isCustom: false
        )
        let span = TimeSpan(start: start, end: end)
        let request = ActivitySectionEditRequest(
            sourceIDs: segment.sourceIDs,
            originalSpan: span,
            originalOption: original,
            mode: .replace(editedSpan: span, option: choice)
        )
        guard await model.saveActivitySectionEdit(request) != nil else { return false }
        refreshTimeRailSegments()
        if calendar.isDate(model.selectedDate, inSameDayAs: selectedDay) {
            selectedTimelineMinute = MapHomeUnconfirmedReviewPolicy.midpointMinute(for: segment)
            isTimelineSelectionPinned = true
        }
        rewardRecentCompletedDay(selectedDay)
        return true
    }

    private func locationDestinationSheet(
        for destination: MapHomeLocationDestination
    ) -> some View {
        MapHomeLocationSheet(
            model: model,
            destination: destination,
            language: language
        ) {
            setMapPosition(.automatic)
            focusMapIfNeeded()
        }
        .presentationDetents([.height(510)])
        .presentationDragIndicator(.visible)
    }

    private func userLocationSheet(
        for selection: MapHomeUserLocationSelection
    ) -> some View {
        MapHomeUserLocationActionSheet(
            model: model,
            selection: selection,
            language: language
        )
        .presentationDetents([.height(300)])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private var searchPinSheet: some View {
        if let selectedSearchPin = self.selectedSearchPin {
            MapHomeSearchPinLocationSheet(
                model: model,
                result: selectedSearchPin,
                language: language,
                onSaved: { createdSelection in
                    pendingUserLocationSelection = createdSelection
                    isSearchPinMenuPresented = false
                    self.selectedSearchPin = nil
                }
            )
            .presentationDetents([.height(540)])
            .presentationDragIndicator(.visible)
            .presentationBackgroundInteraction(
                .enabled(upThrough: .height(540))
            )
        }
    }

    /// 측정용: `-benchHide=rails,topleft`로 영역을 빼고 끊김이 어디서 오는지 가른다(ARC1030A01).
    private static func benchHidden(_ name: String) -> Bool {
        ProcessInfo.processInfo.arguments.contains { $0.hasPrefix("-benchHide=") && $0.contains(name) }
    }

    /// 재생 중에는 초당 한 번만 다시 그리는 영역. 정지 중에는 늘 다시 그린다.
    private func coarseRegion<Content: View>(@ViewBuilder _ content: @escaping () -> Content) -> some View {
        EquatableView(content: MapHomeCoarseView(
            progress: playbackProgress,
            isFrozen: isDayPlaybackRunning,
            content: content
        ))
    }

    /// 측정용: `-autoStartDayPlayback`으로 켜면 지도가 뜬 뒤 재생을 저절로 시작하고 끝나면 로그 패키지를 만든다(PLY1029A08).
    /// 벡터 지도 뷰가 아니라 화면 공통 위치에서 돈다. 지도 스타일을 바꾸면 벡터 지도 뷰가 사라져 안에 둔 작업이 취소됐다(ARC1030A04).
    private func runBenchAutoPlayback() async {
        #if DEBUG || BENCH
        await MapHomeBenchHomeZoom.run(model: model) { mapPosition = .camera($0); mapCameraRevision += 1 }
        if ProcessInfo.processInfo.arguments.contains("-debugOpenDaySummary") { try? await Task.sleep(for: .seconds(15)); isDaySummaryPresented = true }
        if ProcessInfo.processInfo.arguments.contains("-debugOpenClipEditor") { try? await Task.sleep(for: .seconds(15)); openSectionEditor(at: 600) }
        if MapHomeSheetBench.isRequested {
            await MapHomeSheetBench.run(selectDate: { model.selectedDate = $0 }, sheets: [
                ("calendar", { isCalendarPresented = $0 }),
                ("counter", { counterDetail = $0 ? (counterRowTargets.first ?? .kind(.steps)) : nil }),
                ("recording", { isRecordingOptionsPresented = $0 }),
                ("day_summary", { isDaySummaryPresented = $0 }),
            ])
            return
        }
        #endif
        // 측정용: `-autoBenchMapPan`이면 지도가 뜬 뒤 12초 동안 지도를 자동으로 좌우로 밀고(손가락 팬과 같은 경로),
        // 함수별 시간(`playback_probe`)과 프레임 간격(`interaction_stats` bench_pan)을 남긴 뒤 로그 패키지를 만든다(PRF1030A02).
        if ProcessInfo.processInfo.arguments.contains("-autoBenchMapPan") {
            MapHomeBenchHomeZoom.reapplyStyle(model: model)
            try? await Task.sleep(nanoseconds: 25_000_000_000)
            if Task.isCancelled { return }; MapHomeBenchHomeZoom.reapplyStyle(model: model)
            // `-benchSelectMinute=1250`이면 사이드바에서 그 시각을 고른 상태로 민다(실사용 기록과 같은 조건).
            if let value = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("-benchSelectMinute=") })?
                .dropFirst("-benchSelectMinute=".count), let minute = Int(value) {
                selectedTimelineMinute = minute
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
            MapHomePlaybackProbe.start()
            MapHomeInteractionMonitor.shared.begin("bench_pan")
            NotificationCenter.default.post(name: MapHomeVectorMap.Coordinator.benchPanNotification, object: nil)
            try? await Task.sleep(nanoseconds: UInt64(MapHomeVectorMap.Coordinator.benchPanSeconds * 1_000_000_000))
            MapHomeInteractionMonitor.shared.end("bench_pan")
            MapHomePlaybackProbe.stopAndRecord()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await model.exportDiagnosticsToICloud()
            return
        }
        if ProcessInfo.processInfo.arguments.contains("-autoStartDayPlayback") {
            // 측정용: `-benchMapStyle=standard` 등으로 지도 스타일을 골라 Apple 지도와 판타지 지도를 같은 조건에서 비교한다(ARC1030A04).
            if let value = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("-benchMapStyle=") })?
                .dropFirst("-benchMapStyle=".count),
               let style = MapDisplayStyle(rawValue: String(value)) {
                model.setMapDisplayStyle(style)
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            // `-autoPlaybackYesterday`면 어제 하루 전체를 재생해 측정한다(오늘은 새벽이면 너무 짧다).
            if ProcessInfo.processInfo.arguments.contains("-autoPlaybackYesterday"),
               let yesterday = Calendar.autoupdatingCurrent.date(byAdding: .day, value: -1, to: Date()) {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                model.selectedDate = yesterday
                // 어제 데이터·경로·예상 경로를 다 읽을 때까지 기다린다(먼저 재생하면 읽기 끝에 재생이 끊긴다).
                try? await Task.sleep(nanoseconds: 14_000_000_000)
            }
            MapHomeBenchHomeZoom.reapplyStyle(model: model)
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            if Task.isCancelled { return }
            startDayPlayback(fromMidnight: true)
            // 재생이 끝나면 로그 패키지를 저절로 만든다(USB로 받아 본다). 어제처럼 긴 하루는 1분을 넘길 수 있어 끝까지 기다린다.
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            for _ in 0..<MapHomeBenchHomeZoom.playbackWaitTicks where isDayPlaybackRunning {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            if isDayPlaybackRunning { stopDayPlayback(resetProgress: false) }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await model.exportDiagnosticsToICloud()
        }
    }

    private var foregroundContent: some View {
        ZStack(alignment: .top) {
            // 지도·사이드 레일·재생 HUD는 분을 읽는다. 분이 바뀔 때 이 조각만 다시 그리게 따로 감싼다(ARC1030A01).
            MapHomeObservingView {
                // 정지 상태 확대는 지도 화면이 떠 있는 동안만 2초마다 한 걸음(전역 타이머·지도별 중복 구독 대신, PRF1101A01).
                AnyView(map).task {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(2))
                        advanceStationaryZoomIfNeeded()
                    }
                }
                .onChange(of: selectedTimelineMinute) { _, _ in
                    // 선택한 분을 읽는 수식어는 부모 본문이 아니라 이 조각에 둔다(ARC1030A01).
                    if !isTimelineInteractionActive, !isDayPlaybackRunning { recordTimelineWindow("select") }
                }
            }
                .padding(.leading, mapLeadingInset)
                .animation(.easeInOut(duration: 0.22), value: mapLeadingInset)
                .background(Color.tpBackground)
                .ignoresSafeArea()
                .zIndex(MapHomeLayerPriority.map)

            if !Self.benchHidden("rails") { MapHomeObservingView { AnyView(mapSideRails) } }

            if isPlacingMapMemo {
                mapMemoPlacementOverlay
                    .zIndex(MapHomeLayerPriority.loading)
            }

            if !isScreenRecording, !Self.benchHidden("topleft") {
                coarseRegion { AnyView(topLeftControls) }
                    .zIndex(MapHomeLayerPriority.loading)
            }

            if isDayDataLoading {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(language.text("날짜 데이터 불러오는 중", "Loading day data"))
                }
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .semibold))
                .foregroundStyle(Color.tpInk)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.tpSurface.opacity(0.92), in: Capsule())
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .allowsHitTesting(false)
                .zIndex(MapHomeLayerPriority.loading)
            }

            VStack(spacing: 0) {
                Color.clear
                    .frame(height: Layout.headerVisibleHeight + 8)
                    .allowsHitTesting(false)
                if !isScreenRecording,
                   isSearchExpanded || isMapSearchFocused || hasMapSearchResults || !mapSearchText.isEmpty
                    || (selectedSearchPin != nil && pendingLongPressCoordinate == nil) {
                    HStack(alignment: .top, spacing: 0) {
                        mapSearchBar
                    }
                    .mapHomeWideTopOverlay(viewportWidth: mapViewportSize.width)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .padding(.horizontal, Layout.horizontalInset)
            .padding(.top, 2)
            .frame(maxHeight: .infinity, alignment: .top)
            .zIndex(MapHomeLayerPriority.search)

            if isMenuOpen, !isScreenRecording {
                Group { if isWideLayout { AnyView(sidebarContent).mapHomeWidePanelFrame(viewportWidth: mapViewportSize.width, kind: menuPanelKind) } else { menu } }
                    .transition(.move(edge: .leading).combined(with: .opacity))
                    .zIndex(MapHomeLayerPriority.menu)
            }

            if !isScreenRecording {
                dateBadge
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.top, Layout.topRowInset)
                    .padding(.horizontal, Layout.horizontalInset)
                    .zIndex(MapHomeLayerPriority.header)
            }

            // 재생 중에는 상단에 얇은 진행 바를 띄운다. 정지 화면과 구분되게 하는 표시다.
            if isDayPlaybackRunning, !isScreenRecording {
                MapHomeObservingView {
                    MapHomePlaybackHUD(
                        minute: dayPlaybackCurrentMinute ?? Double(selectedTimelineMinute ?? 0),
                        endMinute: playbackHUDEndMinute,
                        language: language
                    )
                }
                .frame(maxWidth: MapHomeWideLayoutPolicy.topOverlayMaximumWidth(viewportWidth: mapViewportSize.width))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, Layout.topRowInset + Layout.dateBadgeSize + 8)
                .padding(.horizontal, Layout.horizontalInset)
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(MapHomeLayerPriority.header)
            }

            if !isScreenRecording, !isMenuOpen || isWideLayout, layoutStyle.movesActionsToBottom {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    AnyView(bottomActionBar)
                        .mapHomeWideActionBar(viewportWidth: mapViewportSize.width)
                }
                .zIndex(MapHomeLayerPriority.header)
            }

            // 화랑이 탭은 모든 층보다 위에서 먼저 받는다(대표 지시). 여기서 하루 요약을 연다.
            if !isScreenRecording, !isMenuOpen || isWideLayout {
                MapHomeObservingView { stickmanTapTarget }
                    .zIndex(MapHomeLayerPriority.header + 1)
            }
        }
        .onChange(of: isDayPlaybackRunning) { _, isRunning in
            if !isRunning { finishRecordingPlayback() }
        }
        .task { await runBenchAutoPlayback() }
        .task(id: model.selectedDate) { await loadPhotoMoments(asksPermission: FirstRunTutorialStore().allowsUnaskedPermissionPrompts) }
        .task(id: model.selectedDate) { await loadDayCalendarEvents() }
        .task {
            // 로딩이 너무 오래 걸리면 시간 제한 후 홈을 연다(무한 로딩 방지).
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            initialReadyForced = true
            reportInitialMapShellReadyIfNeeded(for: model.selectedDate)
        }
        .onAppear {
            TaptionSeasonStore.select(model.selectedDate)
            refreshTimedMemoCache()
            applyPendingMapHomeRoute()
        }
        .onChange(of: model.pendingMapHomeRoute) { _, _ in
            applyPendingMapHomeRoute()
        }
        .onChange(of: model.selectedDate) { _, date in
            TaptionSeasonStore.select(date)
            refreshTimedMemoCache()
            // 날짜가 바뀌면 이전 날짜 일정을 즉시 내린다. 다시 불러오는 동안 옛 목록이
            // 좌측 상단·사이드바에 남아 있으면 날짜를 바꿔도 그대로인 것처럼 보인다.
            dayCalendarEvents = []
            dayCalendarEventsDate = nil
        }
        .onChange(of: model.snapshot.memos) { _, _ in refreshTimedMemoCache() }
        .onChange(of: showsPhotosOnMap) { _, _ in Task { await loadPhotoMoments(asksPermission: true) } }
        // 하루 데이터가 늦게 들어오면 위치 없는 사진의 추정 위치도 다시 맞춘다.
        .onChange(of: isDayDataLoading) { _, loading in
            if !loading, photosNeedReadingRetry { Task { await loadPhotoMoments(asksPermission: false) } }
        }
        .sheet(item: $photoAlbumSelection) { selection in
            MapHomePhotoAlbumSheet(moments: selection.moments, language: language)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $isRecordingOptionsPresented) {
            MapHomeRecordingOptionsSheet(
                layers: Binding(
                    get: { recordingLayers },
                    set: { recordingLayersRaw = $0.rawValue }
                ),
                language: language,
                onStart: startRecordingPlayback,
                onRenderVideo: rendersVectorMap ? {
                    isRecordingOptionsPresented = false
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 450_000_000)
                        isPlaybackVideoPresented = true
                    }
                } : nil,
                adaptiveZoom: Binding(
                    get: { (MapHomePlaybackZoomMode(rawValue: playbackZoomModeRaw) ?? .adaptive) == .adaptive },
                    set: { playbackZoomModeRaw = ($0 ? MapHomePlaybackZoomMode.adaptive : .fixed).rawValue }
                ),
                mapStyleTitle: mapStyleTitle(model.settings.mapDisplayStyle),
                mapStyles: (MapDisplayStyle.openFreeMapStyles + MapDisplayStyle.appleStyles).map { style in
                    MapHomeRecordingMapStyleChoice(
                        id: style.rawValue, title: mapStyleTitle(style), systemImage: mapStyleSystemImage(style),
                        select: { model.setMapDisplayStyle(style) }
                    )
                }
            )
            .presentationDetents([.height(640), .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $isPlaybackVideoPresented) {
            MapHomePlaybackVideoSheet(model: model, language: language, makeRenderer: makePlaybackVideoRenderer)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .alert(
            language.text("화면 녹화", "Screen recording"),
            isPresented: Binding(
                get: { recordingFailureMessage != nil },
                set: { if !$0 { recordingFailureMessage = nil } }
            )
        ) {
            Button(language.text("확인", "OK"), role: .cancel) { recordingFailureMessage = nil }
        } message: {
            Text(recordingFailureMessage ?? "")
        }
        // 공유 시트는 파일 주소가 정해진 뒤에만 연다(주소 없이 열리면 빈 화면이 나온다).
        .sheet(item: $recordedVideoShare) { url in
            MapHomeShareSheet(url: url)
                .presentationDetents([.medium, .large])
        }
    }

    var body: some View {
        let probe = MapHomePlaybackProbe.begin("body")
        MapHomePlaybackProbe.inBody = true
        defer { MapHomePlaybackProbe.inBody = false; MapHomePlaybackProbe.end(probe) }
        return lifecycleModifiers(presentationModifiers(baseContent)).mapHomeDebugViewportWidth()
    }

    /// `body`의 수정자 체인이 길면 타입 검사가 느려져(CI에서 시간 초과) 세 덩어리로 나눈다.
    private var baseContent: some View {
        Group {
            if scenePhase == .background {
                Color.tpSurface.ignoresSafeArea()
            } else {
                foregroundContent
            }
        }
        .coordinateSpace(name: "mapHomeViewport")
        .ignoresSafeArea(.container, edges: .bottom)
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .onGeometryChange(
            for: CGSize.self,
            of: { $0.size },
            action: { size in
                let integralSize = CGSize(
                    width: size.width.rounded(),
                    height: size.height.rounded()
                )
                Task { @MainActor in
                    await Task.yield()
                    guard mapViewportSize != integralSize else { return }
                    mapViewportSize = integralSize
                }
            }
        )
        .preferredColorScheme(TaptionUITheme.current.colorScheme)
    }

    private func presentationModifiers(_ content: some View) -> some View {
        content
        .sheet(item: $selectedMarkerInfo) { info in
            MapHomeMarkerInfoSheet(kind: info, language: language, model: model, placeID: selectedMarkerPlaceID)
                .presentationDetents([.height(320), .medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $counterDetail) { focus in
            let snapshot = counterDetailSnapshot.value(for: focus) {
                // 창에 보이는 카운터를 탭으로 늘어놓고, 누른 줄의 탭을 먼저 고른다.
                let targets = counterRowTargets.contains(focus) ? counterRowTargets : [focus]
                return MapHomeCounterDetailSnapshot.Value(
                    contents: targets.map { counterDetailContent(for: $0) },
                    initialIndex: targets.firstIndex(of: focus) ?? 0,
                    dateText: model.selectedDate.formatted(
                        Date.FormatStyle().month(.wide).day().weekday(.wide)
                            .locale(Locale(identifier: language.text("ko_KR", "en_US")))
                    )
                )
            }
            MapHomeCounterDetailSheet(
                contents: snapshot.contents,
                initialIndex: snapshot.initialIndex,
                dateText: snapshot.dateText
            )
        }
        .mapHomeWidePanel(isPresented: $isDaySummaryPresented, viewportWidth: mapViewportSize.width, language: language) {
            MapHomeDaySummarySheet(
                date: model.selectedDate,
                categories: daySummaryCategories,
                stepCount: dayStepCount,
                travelDistances: MapHomeDayTravelSummary.entries(
                    from: currentDayDataSnapshot?.travel ?? []
                ),
                growthData: $homeGrowthData,
                language: language,
                growthCard: MapHomeGrowthCardInfo(
                    level: homeGrowthHistory.season.level,
                    status: homeGrowthMarkerStatus,
                    isQualifiedToday: isHomeGrowthQualifiedToday,
                    streak: homeGrowthHistory.season.streak,
                    pendingWeeklyRewards: homeGrowthHistory.season.pendingWeeklyRewards
                ),
                homeArtwork: AnyView(daySummaryHomeArtwork),
                salary: salaryLive,
                memoCounts: dayMemoCounts,
                model: model,
                homePlaceID: model.settings.frequentPlaces.first { $0.kind == .home }?.id,
                detent: $daySummaryDetent
            )
            .presentationDragIndicator(.visible)
        }
        // 시트가 올라오고 내려갈 때마다 집을 가려지지 않은 지도 영역 가운데로 다시 맞춘다.
        .onChange(of: isDaySummaryPresented) { _, presented in
            if !presented {
                daySummaryFocusesCat = false
                // 다음에 열 때는 다시 접힌 높이에서 시작한다.
                daySummaryDetent = MapHomeDaySummarySheet.collapsedDetent
            }
            applyDaySummaryCameraCoverage()
        }
        .onChange(of: daySummaryDetent) { _, _ in
            applyDaySummaryCameraCoverage()
        }
        .sheet(isPresented: $isCarAudioSheetPresented, onDismiss: {
            // 등록을 바꾸면 오늘 이동을 다시 판정한다.
            Task { _ = await model.refreshSensorTimeline() }
        }) {
            MapHomeCarAudioSheet(model: model, language: language)
        }
        .sheet(isPresented: $isSalarySettingsPresented) {
            MapHomeSalarySettingsSheet(
                language: language,
                monthWorkSeconds: salaryLive?.month?.workSeconds ?? 0,
                projectedMonthWorkSeconds: salaryLive?.projectedMonthWorkSeconds ?? 0,
                pastMonthWorkSeconds: salaryLive?.pastMonthWorkSeconds ?? [:]
            )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        // 연봉을 넣었으면 30초마다 오늘 근무 시간을 다시 센다(사이 값은 지도 라벨이 표시 간격마다 더한다).
        // 기록을 다 불러오기 전(앱 시작 직후)에 센 0을 붙들지 않게, 기록 개수가 바뀌면 처음부터 다시 센다.
        .task(id: salaryTaskID) {
            guard scenePhase == .active else { return }
            var monthComputedAt: Date?
            while !Task.isCancelled {
                let needsMonth = monthComputedAt.map { Date.now.timeIntervalSince($0) >= 300 } ?? true
                await refreshSalary(includeMonth: needsMonth)
                if needsMonth { monthComputedAt = .now }
                try? await Task.sleep(for: .seconds(30))
            }
        }
        .alert(
            language.text("집이 등록돼 있지 않아요", "No home place yet"),
            isPresented: $isHomeMissingAlertPresented
        ) {
            Button(language.text("나중에", "Not now"), role: .cancel) {}
            Button(language.text("위치 설정 열기", "Open location settings")) { openLocationSettings() }
        } message: {
            Text(language.text("메뉴 > 위치에서 집을 먼저 등록해 주세요.", "Add your home in Menu > Location first."))
        }
        .sheet(isPresented: $isStrideCalibrationPresented) {
            MapHomeStrideCalibrationSheet(language: language)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .mapHomeWidePanel(isPresented: $isCalendarPresented, kind: .calendar, title: language.text("달력", "Calendar"), viewportWidth: mapViewportSize.width, language: language) {
            MapHomeCalendarSheet(
                selectedDate: $model.selectedDate,
                holidayName: { date in
                    TimelineAxisGrid.koreanHolidayName(on: date)
                },
                logStatuses: { month in
                    let actuals = model.snapshot.actuals
                    let travel = model.snapshot.travel
                    let base = await Task.detached(priority: .userInitiated) {
                        MapHomeCalendarLogStatusPolicy.statuses(
                            actuals: actuals,
                            travel: travel,
                            month: month,
                            asOf: .now,
                            calendar: MapHomeGrowthPolicy.localCalendar
                        )
                    }.value
                    return await calendarLogStatusesFillingGaps(base, month: month)
                },
                timeTotals: { month in await calendarTimeTotals(month: month, includePhotos: true) },
                liveTotals: { month in await calendarTimeTotals(month: month, includePhotos: false) },
                placeVisits: { day in
                    let stays = model.snapshot.places
                    guard let dayEnd = MapHomeGrowthPolicy.localCalendar.date(byAdding: .day, value: 1, to: day) else { return [] }
                    return await Task.detached(priority: .userInitiated) {
                        MapHomeCalendarPlaceVisitPolicy.visits(stays: stays, day: day, dayEnd: dayEnd)
                    }.value
                },
                timeTint: { categoryID in
                    MapHomeSidebarMajorCategory.presentation(
                        for: categoryID,
                        categoryColors: model.settings.mapCategoryColors
                    ).tint
                },
                language: language,
                // 달력 빠른 갱신은 15초 단위로만 다시 계산한다(달 전체 재계산 부담을 줄임).
                liveToken: ((model.latestSensorReading?.timestamp.timeIntervalSince1970 ?? 0) / 15).rounded(.down)
            )
        }
        .sheet(item: $selectedLocationDestination) { destination in
            locationDestinationSheet(for: destination)
        }
        .sheet(isPresented: $isTransitLocationsPresented) {
            MapHomeTransitLocationsSheet(
                model: model,
                language: language,
                initialCenter: currentCoordinate ?? visibleMapCenter,
                initialSpan: visibleMapSpan
            )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $selectedUserLocation) { selection in
            userLocationSheet(for: selection)
        }
        .sheet(item: $selectedMapStickerEditor) { target in
            MapHomeStickerEditorSheet(
                model: model,
                target: target,
                language: language,
                onRequestLocation: { id in beginMemoLocationPick(id) }
            )
        }
        .sheet(item: $selectedTransitBoardingCandidate) { candidate in
            MapHomeTransitBoardingCandidateSheet(
                model: model,
                candidate: candidate,
                language: language
            )
            .presentationDetents([.height(270)])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $selectedPredictedRoute) { route in
            MapHomePredictedRouteMenu(model: model, route: route, language: language)
                .presentationDetents([.height(230)])
                .presentationDragIndicator(.visible)
        }
        .sheet(
            isPresented: $isSearchPinMenuPresented,
            onDismiss: {
                if let selection = pendingUserLocationSelection {
                    pendingUserLocationSelection = nil
                    selectedUserLocation = selection
                } else {
                    selectedSearchPin = nil
                }
            }
        ) {
            searchPinSheet
        }
        .onReceive(NotificationCenter.default.publisher(for: .taptionPlanAlarmTapped)) { note in
            guard let raw = note.userInfo?["kind"] as? String, let kind = MapHomeAlarmKind(rawValue: raw) else { return }
            if kind == .dailyCard {
                openDailyCardFromAlarm(fireDate: note.userInfo?["fire"] as? Date ?? .now)
                return
            }
            // 시간은 지금으로 채운다(알람을 보낸 시각이 아니라, 실제로 확인하는 시각).
            pendingAlarm = (kind, .now)
        }
        .sheet(item: alarmConfirmBinding) { item in
            MapHomeAlarmConfirmSheet(
                kind: item.kind,
                initialDate: item.at,
                language: language,
                onConfirm: { date in
                    if let entry = MapHomeAlarmRecordMapping.entry(for: item.kind, language: language) {
                        model.confirmAlarmRecord(categoryID: entry.categoryID, title: entry.title, at: date, opens: entry.opens)
                    }
                    pendingAlarm = nil
                },
                onCancel: { pendingAlarm = nil }
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $isAlarmSettingsPresented) {
            MapHomeAlarmSettingsSheet(language: language)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .mapHomeWidePanel(isPresented: $isDailyCardPresented, title: language.text("하루 카드", "Day card"), viewportWidth: mapViewportSize.width, language: language) {
            MapHomeDailyCardSheet(
                initialDay: model.selectedDate,
                language: language,
                makeContent: { await dailyCardContent(for: $0) }
            )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        // 알림 판정: 기록이 바뀔 때마다(장소 머묾·수면·시급) 켜 둔 알림만 보낸다. 하루 카드 예약도 맞춘다.
        .task(id: "\(model.snapshot.places.count)|\(model.snapshot.actuals.count)|\(salaryLive?.hourlyRate ?? 0)") {
            await MapHomeAlarmCenter.shared.syncDailyCardSchedule(language: language)
            let snap = model.snapshot
            let readings = await model.readingsForAlarmCheck(on: .now)
            await MapHomeAlarmCenter.shared.evaluate(
                actuals: snap.actuals,
                travel: snap.travel,
                stays: snap.places,
                frequentPlaces: snap.settings.frequentPlaces,
                readings: readings,
                language: language
            )
            if let salaryLive {
                await MapHomeAlarmCenter.shared.noteRate(
                    salaryLive.hourlyRate,
                    isWorking: salaryLive.isWorking,
                    breakEvenHours: salaryLive.isWorking ? MapHomeAlarmPolicy.breakEvenHours(
                        settings: MapHomeSalaryPolicy.loadSettings(),
                        monthWorkSeconds: salaryLive.month?.workSeconds ?? 0,
                        projectedMonthWorkSeconds: salaryLive.projectedMonthWorkSeconds,
                        samples: []
                    ) : nil,
                    language: language
                )
            }
        }
        .sheet(isPresented: $isMapAttributionPresented) {
            MapHomeAttributionSheet(language: language)
                .presentationDetents([.height(360), .large])
                .presentationDragIndicator(.visible)
        }
        // + 버튼은 바로 메모 편집 화면을 연다. 시간·위치·스티커는 그 화면에서 고른다.
        .confirmationDialog(
            language.text("지도에 메모 추가", "Add map memo"),
            isPresented: $isLongPressMenuPresented,
            titleVisibility: .visible
        ) {
            Button(language.text("추가", "Add")) { routeLongPress(.memo) }
            Button(language.text("취소", "Cancel"), role: .cancel) {
                pendingLongPressCoordinate = nil
                selectedSearchPin = nil
            }
        }
        .overlay {
            if isDayPlaybackRunning, let cat = displayedStickmanViewportPoint, let minute = dayPlaybackCurrentMinute {
                MapHomePlaybackMomentsOverlay(minute: minute, events: playbackMomentEvents, anchor: cat)
            }
        }
        .sheet(isPresented: $isCalendarConnectPresented) { MapHomeCalendarConnectSheet(model: model, language: language) }
        .sheet(isPresented: $isDataProtectionPresented) {
            MapHomeSecuritySheet(model: model, language: language)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $isCategoryAddPresented) {
            MapHomeCategoryAddSheet(model: model, language: language)
                .presentationDetents([.height(320)])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $proAccess.isPurchaseSheetPresented) {
            TaptionProAccessView(
                controller: proAccess,
                allowsDismiss: true
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(
            isPresented: $isUnconfirmedReviewPresented,
            onDismiss: {
                focusedUnconfirmedReviewSegment = nil
                guard let minute = pendingUnconfirmedEditMinute else { return }
                pendingUnconfirmedEditMinute = nil
                Task { @MainActor in
                    await Task.yield()
                    openSectionEditor(at: minute)
                }
            }
        ) {
            MapHomeUnconfirmedReviewSheet(
                date: model.selectedDate,
                segments: timeRailSegments,
                focusedSegment: focusedUnconfirmedReviewSegment,
                recentDates: focusedUnconfirmedReviewSegment == nil
                    ? MapHomeUnconfirmedReviewPolicy.recentDates()
                    : [],
                language: language,
                onDateSelect: { day in
                    guard !Calendar.autoupdatingCurrent.isDate(day, inSameDayAs: model.selectedDate) else { return }
                    model.selectedDate = day
                    refreshTimeRailSegments()
                },
                onSelect: { segment in
                    pendingUnconfirmedEditMinute = MapHomeUnconfirmedReviewPolicy
                        .midpointMinute(for: segment)
                    isUnconfirmedReviewPresented = false
                },
                onQuickConfirm: { segment, category in
                    await quickConfirmUnconfirmed(segment, as: category)
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .confirmationDialog(
            language.text("설정을 기본값으로 초기화할까요?", "Reset settings to defaults?"),
            isPresented: $isSettingsResetConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button(language.text("설정 초기화", "Reset settings"), role: .destructive) {
                isMenuOpen = false
                Task { await model.resetSettingsToDefaults() }
            }
            Button(language.text("취소", "Cancel"), role: .cancel) {}
        } message: {
            Text(language.text("계획과 기록은 삭제되지 않습니다.", "Your plans and records will not be deleted."))
        }
        .fullScreenCover(
            item: $sectionEditSelection,
            onDismiss: {
                sectionEditSelection = nil
                refreshTimeRailSegments()
            }
        ) { selection in
            // 행동구간 편집에 들어가면 클립 편집기를 바로 연다. 기존 행동구간
            // 편집 화면은 아래 한 줄을 되살리면 그대로 돌아온다.
            // sectionEditSheet(for: selection)
            clipEditorSheet(for: selection)
        }
        .animation(.easeInOut(duration: 0.22), value: isMenuOpen)
        .mapHomeWidePanelsExclusive(viewportWidth: mapViewportSize.width, [$isMenuOpen, $isCalendarPresented, $isDaySummaryPresented, $isDailyCardPresented, $isSearchExpanded, $todayCalendarExpanded])
        .onChange(of: isMenuOpen) { _, isOpen in
            guard isOpen else { return }
            Task { @MainActor in await model.refreshPermissions() }
        }
    }

    /// 사슬이 길면 타입 검사가 수십 초 걸려(43초, ARC1103A01) 세 덩어리로 나눈다. 수식어 순서는 그대로다.
    private func lifecycleModifiers(_ content: some View) -> some View {
        lifecycleLiveRouteModifiers(lifecycleDataModifiers(lifecycleSessionModifiers(content)))
    }

    private func lifecycleSessionModifiers(_ content: some View) -> some View {
        content
        .onAppear {
            if scenePhase == .active { restoreInitialMapZoom() }
            prepareRouteProjectionReadings()
            refreshHomeGrowth(at: .now)
        }
        .onChange(of: model.snapshotRevision) { _, _ in
            refreshHomeGrowth(at: .now)
        }
        .onChange(of: model.dayProjectionRevision) { _, _ in
            routeActualIndex = nil
        }
        // 팝업·시트가 열리는 1.2초 동안의 화면 틱을 잰다(ARC1030A07).
        .onChange(of: isCalendarPresented) { _, on in MapHomeInteractionMonitor.shared.begin(on ? "popup_calendar" : "popup_calendar_close", duration: 1.2) }
        .onChange(of: isDaySummaryPresented) { _, on in MapHomeInteractionMonitor.shared.begin(on ? "popup_day_summary" : "popup_day_summary_close", duration: 1.2) }
        .onChange(of: counterDetail != nil) { _, on in
            if !on { counterDetailSnapshot.clear() }
            MapHomeInteractionMonitor.shared.begin(on ? "popup_counter_detail" : "popup_counter_detail_close", duration: 1.2)
        }
        .onChange(of: isMenuOpen) { _, on in if on { MapHomeInteractionMonitor.shared.begin("popup_menu", duration: 1.2) } }
        .onChange(of: isDateWeekExpanded) { _, on in if on { MapHomeInteractionMonitor.shared.begin("popup_date_strip", duration: 1.2) } }
        .onChange(of: isRecordingOptionsPresented) { _, on in MapHomeInteractionMonitor.shared.begin(on ? "popup_recording" : "popup_recording_close", duration: 1.2) }
        .onChange(of: sectionEditSelection != nil) { _, on in if on { MapHomeInteractionMonitor.shared.begin("popup_clip_editor", duration: 1.2) } }
        .onChange(of: playbackZoomModeRaw) { _, raw in
            // 재생 중에 설정을 바꿔도 곧바로 적용한다.
            playbackDriver?.isAdaptiveZoom = MapHomePlaybackZoomMode(rawValue: raw) != .fixed
        }
        .onChange(of: model.isBootstrapped) { _, isReady in
            if isReady { refreshHomeGrowth(at: .now) }
        }
        .onChange(of: model.selectedDate) { _, _ in
            refreshHomeGrowth(at: .now)
        }
        .onDisappear {
            routeReadingsPreparationTask?.cancel()
            routeReadingsPreparationTask = nil
            routeReadingsPreparationGeneration.advance()
            lastPreparedRouteReadingsSignature = nil
            currentLocationRequestTask?.cancel()
            currentLocationRequestTask = nil
            initialLocationRequestTask?.cancel()
            initialLocationRequestTask = nil
            mapSearchTask?.cancel()
            mapSearchTask = nil
            expectedRouteRefreshTask?.cancel()
            expectedRouteRefreshTask = nil
            expectedRouteRefreshGeneration &+= 1
            liveRouteProjectionRefreshTask?.cancel()
            liveRouteProjectionRefreshTask = nil
            transitPOIRefreshTask?.cancel()
            transitPOIRefreshTask = nil
            mapSearchCompleter.clear()
            stopDayPlayback(resetProgress: true)
            headingMonitor.stop()
        }
    }

    private func lifecycleDataModifiers(_ content: some View) -> some View {
        content
        .task(id: daySourceTaskKey) { await runDaySourceTask() }
        .task(id: routeReadingsTaskKey) { await runRouteReadingsTask() }
        .onChange(
            of: MapHomeRouteReadingsPreparation.latestRouteInputSignature(
                model.latestSensorReading
            )
        ) { _, _ in
            guard Calendar.autoupdatingCurrent.isDateInToday(
                model.selectedDate
            ) else { return }
            if refreshTransitBoardingCandidatesIfNeeded(
                at: model.latestSensorReading?.timestamp ?? .now
            ) {
                scheduleTransitPOIRefresh()
            }
            scheduleLiveRouteProjectionRefresh()
            scheduleExpectedRouteRefresh()
        }
        .onChange(of: currentMapLocationReading?.id) { _, _ in
            applyInitialLocationIfAvailable(using: nil)
            guard selectedTimelineMinute == nil,
                  Calendar.autoupdatingCurrent.isDateInToday(model.selectedDate),
                  userTrackingMode.keepsCameraLocked
            else { return }
            focusDisplayedLocation(using: nil)
        }
        .onChange(of: model.settings.frequentPlaces) { _, _ in
            focusMapIfNeeded()
        }
        .onChange(of: model.snapshot.weather) { _, weather in
            cachedWeatherContexts = MapHomeWeatherDisplayCache.merged(
                cached: cachedWeatherContexts,
                incoming: weather
            )
        }
        .onChange(of: model.selectedDate) { _, _ in sidebarNote = nil }
        .onChange(of: model.settings.mapDisplayStyle) { _, _ in
            mapCameraRevision &+= 1
            persistMapDayCache()
        }
        .onChange(of: isNearHomeLand) { _, near in applyAutoLandStyle(near: near) }
        .onChange(of: timeSidebarVisibleDurationMinutes) { _, _ in recordTimelineWindow("zoom") }
        // 잠금 화면 활동 카드에 같은 연봉 글자를 보여 주기 위해 기기 설정에 적어 둔다.
        .onChange(of: salaryLive) { _, _ in
            persistSalaryForLockScreen()
        }
    }

    private func lifecycleLiveRouteModifiers(_ content: some View) -> some View {
        content
        .onChange(of: model.selectedDate) { oldDate, newDate in
            let calendar = Calendar.autoupdatingCurrent
            let dayChanged = !calendar.isDate(oldDate, inSameDayAs: newDate)
            stopDayPlayback(resetProgress: true)
            selectedTimelineMinute = nil
            isTimelineSelectionPinned = false

            if dayChanged {
                resetDayScopedMapState(for: newDate)
                hasUserAdjustedMap = false
                routeReadingsLoadState = .loading(
                    MapHomeRouteReadingsPolicy.dayKey(for: newDate)
                )
                lastTransitBoardingLiveRefreshAt = nil
                transitBoardingReadingsRevision &+= 1
                nearbyTransitPlacesRevision &+= 1
            } else {
                prepareRouteProjectionReadings()
                refreshRouteProjection()
                recordCurrentPlaybackAlignment()
            }

            let shouldFitRoutes = shouldFitRoutesAfterDateChange
            shouldFitRoutesAfterDateChange = false
            if shouldFitRoutes || dayChanged {
                setMapPosition(.automatic)
                focusMapIfNeeded()
            } else if calendar.isDateInToday(newDate),
                      currentCoordinate != nil {
                focusUserLocation()
            }
            refreshTimeRailSegments()
        }
        .onChange(of: model.sleepSessions) { _, _ in
            requestRouteProjectionRefresh(preparingReadings: true)
            scheduleExpectedRouteRefresh()
        }
        .onChange(of: model.settings.confirmedSleepSpans) { _, _ in
            requestRouteProjectionRefresh()
            scheduleExpectedRouteRefresh()
        }
        .onChange(of: model.backupRestoreRevision) { _, _ in
            Task {
                await refreshRouteReadings(
                    for: model.selectedDate,
                    forceReload: true
                )
                scheduleExpectedRouteRefresh()
            }
        }
        .onChange(of: model.liveRouteState.readings.last?.id) { _, _ in
            guard Calendar.autoupdatingCurrent.isDateInToday(
                model.selectedDate
            ) else { return }
            if refreshTransitBoardingCandidatesIfNeeded(
                at: model.liveRouteState.readings.last?.timestamp ?? .now
            ) {
                scheduleTransitPOIRefresh()
            }
            scheduleLiveRouteProjectionRefresh()
            scheduleExpectedRouteRefresh()
        }
        .onChange(of: model.liveRouteState.lastUpdatedAt) { _, _ in
            guard Calendar.autoupdatingCurrent.isDateInToday(
                model.selectedDate
            ) else { return }
            prepareRouteProjectionReadings()
            scheduleLiveRouteProjectionRefresh()
            scheduleExpectedRouteRefresh()
        }
        .onChange(of: scenePhase) { _, phase in
            if startupCameraPolicy.shouldRestoreZoom(on: phase) {
                restoreInitialMapZoom()
            }
            if phase != .active {
                routeReadingsPreparationTask?.cancel()
                routeReadingsPreparationTask = nil
                routeReadingsPreparationGeneration.advance()
                lastPreparedRouteReadingsSignature = nil
                liveRouteProjectionRefreshTask?.cancel()
                liveRouteProjectionRefreshTask = nil
                expectedRouteRefreshTask?.cancel()
                expectedRouteRefreshTask = nil
                expectedRouteRefreshGeneration &+= 1
                pendingForecastRouteState = nil
                routeDocumentProjectionGate.reset()
                transitPOIRefreshTask?.cancel()
                transitPOIRefreshTask = nil
                transitPOIRefreshGeneration &+= 1
                stopDayPlayback(resetProgress: true)
            } else {
                refreshHomeGrowth(at: .now)
                refreshTimeRailSegments()
                transitBoardingReadingsRevision &+= 1
                scheduleTransitPOIRefresh()
                scheduleExpectedRouteRefresh()
                prepareRouteProjectionReadings()
            }
        }
    }

    @ViewBuilder
    private var map: some View {
        // 지도 provider가 OpenFreeMap(벡터, RPG 등)이면 무료 벡터 렌더러를 쓰고,
        // Apple 스타일이면 기존 MapKit 경로를 유지한다. 경로 재생·마커는 벡터
        // 렌더러도 지원한다(MapHomeVectorRoute/Marker).
        if let vectorStyle = model.settings.mapDisplayStyle.runtimeStyle.mapHomeVectorStyle {
            vectorMap(style: vectorStyle)
        } else {
            mapKitMap
                .overlay { appleSalaryOverlay }
        }
    }

    /// Apple 지도에서도 카운터 창을 화랑이 머리 위에 띄운다(벡터 지도와 같은 위치 규칙).
    /// 지도가 움직이는 동안은 프레임마다 받은 점(`appleStickmanLivePoint`)을 화면 틱마다 읽어 화랑이와 함께 옮긴다.
    private var appleSalaryOverlay: some View {
        GeometryReader { geometry in
            if let stickman = displayedStickmanViewportPoint,
               CGRect(origin: .zero, size: geometry.size).contains(stickman),
               recordingShows(\.counterWidget) {
                counterWindow(at: CGPoint(
                    x: stickman.x,
                    y: stickman.y + MapHomeStickmanAnnotationLayout.centerOffset.y - 42
                ), tracksAppleCamera: true)
            }
        }
        .allowsHitTesting(false)
    }

    private var mapStickersOnMap: [MapSticker] {
        MapStickerDisplayFilterEngine.visibleMapStickers(
            model.snapshot.stickers,
            on: model.selectedDate
        ).filter { $0.point.map(isValid) == true }
    }

    private var mapMemosOnMap: [ActionMemo] {
        guard memoDisplayMode != .hidden else { return [] }
        return MapMemoDisplayFilterEngine.visibleMemos(
            model.snapshot.memos,
            on: model.selectedDate,
            filter: model.settings.mapMemoDisplayFilter,
            selectedPlanIDs: mapMemoRelevantPlanIDs,
            selectedTargetIDs: [],
            through: isDayPlaybackRunning ? routeTimelineDate : nil
        )
        .filter { $0.mapPoint.map(isValid) == true }
        .sorted {
            if $0.occurredAt != $1.occurredAt {
                return $0.occurredAt < $1.occurredAt
            }
            return $0.createdAt < $1.createdAt
        }
    }

    private var mapMemoRelevantPlanIDs: Set<UUID> {
        let calendar = Calendar.autoupdatingCurrent
        let start = calendar.startOfDay(for: model.selectedDate)
        let end = calendar.date(byAdding: .day, value: 1, to: start)
            ?? start.addingTimeInterval(86_400)
        return Set(
            model.snapshot.plans
                .filter { $0.span.start < end && $0.span.end > start }
                .map(\.id)
        )
    }

    /// 선택한 날의 시간이 있는 메모(지도 핀이 아닌 것). 사이드바에 메모 아이콘으로 기본 표시한다.
    private var timedMemosForSelectedDate: [ActionMemo] { memoDisplayMode == .hidden ? [] : timedMemoCache }

    /// 선택한 날의 시간 메모 목록을 한 번만 계산해 둔다(배지마다 전체 메모를 다시 훑지 않도록).
    private func refreshTimedMemoCache() {
        timedMemoCache = model.snapshot.memos.filter {
            $0.isTimeless != true
                && $0.mapPoint == nil
                && !model.isMemoDraft($0.id)
                && Self.hasText($0)
                && Calendar.autoupdatingCurrent.isDate($0.occurredAt, inSameDayAs: model.selectedDate)
        }
    }

    private var scheduleStickersForSelectedDate: [MapSticker] {
        model.snapshot.stickers.filter {
            $0.placement == .schedule
                && Calendar.autoupdatingCurrent.isDate(
                    $0.occurredAt,
                    inSameDayAs: model.selectedDate
                )
        }
    }

    private var selectedSchedulePlanIDs: Set<UUID> {
        let selectedDate = timelineSelectionDate
        return Set(
            model.snapshot.plans
                .filter { $0.span.start <= selectedDate && selectedDate < $0.span.end }
                .map(\.id)
        )
    }

    private var mapCenterPoint: GeoPoint? {
        let candidate = visibleMapCenter
        if candidate.latitude.isFinite,
           candidate.longitude.isFinite,
           (-90...90).contains(candidate.latitude),
           (-180...180).contains(candidate.longitude),
           candidate.latitude != 0 || candidate.longitude != 0 {
            return GeoPoint(
                latitude: candidate.latitude,
                longitude: candidate.longitude,
                altitude: 0,
                horizontalAccuracy: 0,
                verticalAccuracy: 0
            )
        }
        guard let currentCoordinate else { return nil }
        return GeoPoint(
            latitude: currentCoordinate.latitude,
            longitude: currentCoordinate.longitude,
            altitude: 0,
            horizontalAccuracy: 0,
            verticalAccuracy: 0
        )
    }

    /// 사이드바(선택 시각, 없으면 지금)가 일정 메모 시각의 앞뒤 30분 안에 오면 보여 주는 메모. 가장 가까운 하나.
    private var nearbyScheduleMemo: MapSticker? {
        MapHomeMemoPreviewPolicy.nearest(
            in: model.snapshot.stickers,
            at: timelineSelectionDate,
            selectedDate: model.selectedDate,
            dismissed: dismissedMemoPreviewIDs
        )
    }

    private func scheduleMemoPreview(_ memo: MapSticker) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: memo.systemImage)
                .font(.system(size: TaptionType.scaled(TaptionType.snapped(16)), weight: .bold))
                .foregroundStyle(Color(hex: memo.colorHex))
                .frame(width: 30, height: 30)
                .background(Color.white.opacity(0.96), in: Circle())
                .overlay(Circle().stroke(Color(hex: memo.colorHex), lineWidth: 1))
            VStack(alignment: .leading, spacing: 3) {
                Text(memo.title)
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(14)), weight: .bold))
                    .lineLimit(1)
                if let text = memo.memo, !text.isEmpty {
                    Text(text)
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .medium))
                        .foregroundStyle(Color.tpSecondary)
                        .lineLimit(2)
                }
                Text(memo.occurredAt.formatted(date: .omitted, time: .shortened))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .semibold))
                    .foregroundStyle(Color.tpSecondary)
            }
            .foregroundStyle(Color.tpInk)
            Spacer(minLength: 4)
            Button {
                dismissedMemoPreviewIDs.insert(memo.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .bold))
                    .foregroundStyle(Color.tpSecondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(language.text("닫기", "Dismiss"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: 280, alignment: .leading)
        .background(Color.tpSurface.opacity(0.97), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.tpLine.opacity(0.8), lineWidth: 0.8)
        }
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        .contentShape(Rectangle())
        .onTapGesture { selectedMapStickerEditor = .sticker(memo.id) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(language.text("일정 메모 \(memo.title)", "Schedule memo \(memo.title)"))
        .transition(.opacity)
    }

    // MARK: 통합 메모 표시

    private var memoDisplayMode: MapHomeMemoDisplayMode {
        MapHomeMemoDisplayMode(rawValue: memoDisplayRaw) ?? .all
    }

    /// 시간을 지정하지 않았고 위치도 없는 메모: 왼쪽 위에 큐처럼 쌓인다(오래된 것이 위).
    /// 선택한 날짜의 메모(시각 있는 메모 + 시각 없이 그날 만든 메모, 지도 메모 포함). 시각 없는 메모가 위, 그 다음 시각 순.
    private var queuedMemos: [ActionMemo] {
        let calendar = Calendar.autoupdatingCurrent
        func onSelectedDay(_ date: Date) -> Bool { calendar.isDate(date, inSameDayAs: model.selectedDate) }
        return model.snapshot.memos
            .filter { memo in
                guard !model.isMemoDraft(memo.id), Self.hasText(memo) else { return false }
                return memo.isTimeless == true ? onSelectedDay(memo.createdAt) : onSelectedDay(memo.occurredAt)
            }
            .sorted { lhs, rhs in
                let lhsTimed = lhs.isTimeless != true, rhsTimed = rhs.isTimeless != true
                if lhsTimed != rhsTimed { return !lhsTimed }
                return lhsTimed ? lhs.occurredAt < rhs.occurredAt : lhs.createdAt < rhs.createdAt
            }
    }

    /// 내용이 비어 있는 메모(취소된 빈 초안 등)는 화면에 올리지 않는다.
    private static func hasText(_ memo: ActionMemo) -> Bool {
        !memo.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 시간은 있고 위치는 없는 메모: 사이드바 시각이 앞뒤 30분 안이면 가장 가까운 하나를 보여 준다.
    private var nearbyTimedMemo: ActionMemo? {
        let calendar = Calendar.autoupdatingCurrent
        let center = timelineSelectionDate
        return model.snapshot.memos
            .filter {
                $0.isTimeless != true && $0.mapPoint == nil && !model.isMemoDraft($0.id)
                    && Self.hasText($0) && !dismissedMemoPreviewIDs.contains($0.id)
                    && calendar.isDate($0.occurredAt, inSameDayAs: model.selectedDate)
                    && abs($0.occurredAt.timeIntervalSince(center)) <= 15 * 60
                    && $0.planID == nil
            }
            .min { abs($0.occurredAt.timeIntervalSince(center)) < abs($1.occurredAt.timeIntervalSince(center)) }
    }

    /// 왼쪽 상단: 메모 원형 버튼과 구글 일정 버튼. 일정을 누르면 오늘 일정 목록이 펼쳐진다.
    /// 메뉴 단추는 하단 맨 왼쪽으로 내렸다(대표 요청, 2026-10-26).
    private var topLeftControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 날짜 줄이 이 자리를 덮을 때만(아이폰 폭) 숨긴다.
            if !isDateWeekExpanded || !MapHomeWideLayoutPolicy.dateStripOverlapsTopLeftControls(viewportWidth: mapViewportSize.width) {
                HStack(spacing: 8) {
                    searchCircleButton
                    if recordingShows(\.sidebarMemos), memoDisplayMode == .all {
                        memoCircleButton
                    }
                    MapHomeCalendarButton(isExpanded: todayCalendarExpanded, count: dayCalendarEventsForSelectedDate.count) {
                        switch calendarAccessProblem {
                        case .googleFailed:
                            model.selectTab(.settings)
                        case .permissionDenied:
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        case nil:
                            withAnimation(.snappy) { todayCalendarExpanded.toggle() }
                        }
                    }
                }
            }
            // 현재 시간 ±15분 안의 메모·일정은 목록을 펼치지 않아도 왼쪽 상단에 보인다.
            if !nearbyPreviewRows.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(nearbyPreviewRows, id: \.id) { row in
                        HStack(spacing: 6) {
                            Image(systemName: row.systemImage)
                                .font(.system(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .bold))
                                .foregroundStyle(Color.tpReferenceBlue)
                            Text(row.title)
                                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .semibold))
                                .foregroundStyle(Color.tpInk)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text(row.time)
                                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .medium))
                                .foregroundStyle(Color.tpSecondary)
                        }
                    }
                }
                .padding(10)
                .frame(width: 240, alignment: .leading)
                .mapHomeGlass(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            // 먼저 연 패널이 위에 오고, 나중에 연 패널은 그 아래에 붙는다. 폭은 같다.
            ForEach(topPanelOrder, id: \.self) { panel in
                switch panel {
                case .memo:
                    if memoStackExpanded, recordingShows(\.sidebarMemos), memoDisplayMode == .all {
                        memoListPanel
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                case .calendar:
                    if todayCalendarExpanded {
                        MapHomeTodayCalendarList(
                            language: language,
                            service: calendarService,
                            date: model.selectedDate,
                            titleDetails: model.snapshot.settings.calendarTitleDetails,
                            onChooseDetail: { title, choice in
                                Task {
                                    switch choice {
                                    case .automatic: await model.clearCalendarTitleDetail(title: title, on: model.selectedDate)
                                    case .none: await model.setCalendarTitleDetail(nil, title: title, on: model.selectedDate)
                                    case .detail(let id): await model.setCalendarTitleDetail(id, title: title, on: model.selectedDate)
                                    }
                                }
                            }
                        )
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.leading, Layout.horizontalInset)
        .padding(.top, Layout.topRowInset)
        .onChange(of: memoStackExpanded) { _, open in setTopPanel(.memo, open: open) }
        .onChange(of: todayCalendarExpanded) { _, open in setTopPanel(.calendar, open: open) }
    }

    enum TopPanel: Hashable { case memo, calendar }

    private func setTopPanel(_ panel: TopPanel, open: Bool) {
        topPanelOrder.removeAll { $0 == panel }
        if open { topPanelOrder.append(panel) }
    }

    struct NearbyPreviewRow: Identifiable {
        let id: String
        let systemImage: String
        let title: String
        let time: String
    }

    /// 현재 시간 ±15분 안의 메모와 일정 목록(왼쪽 상단 미리보기).
    private var nearbyPreviewRows: [NearbyPreviewRow] {
        let center = timelineSelectionDate
        let window: TimeInterval = 15 * 60
        var rows: [NearbyPreviewRow] = []
        if let memo = nearbyTimedMemo {
            rows.append(NearbyPreviewRow(
                id: "memo-\(memo.id.uuidString)",
                systemImage: "note.text",
                title: memo.text,
                time: memo.occurredAt.formatted(date: .omitted, time: .shortened)
            ))
        }
        for event in dayCalendarEventsForSelectedDate where !event.isAllDay
            && abs(event.span.start.timeIntervalSince(center)) <= window {
            rows.append(NearbyPreviewRow(
                id: "event-\(event.id)",
                systemImage: "calendar",
                title: event.title,
                time: event.span.start.formatted(date: .omitted, time: .shortened)
            ))
        }
        return rows
    }

    /// 화면에 쓸 일정. 아직 다른 날짜의 목록을 들고 있으면(날짜를 막 바꾼 직후) 빈 목록으로
    /// 두어 이전 날짜 일정이 좌측 상단·사이드바에 남지 않게 한다.
    private var dayCalendarEventsForSelectedDate: [CalendarRecord] {
        guard let day = dayCalendarEventsDate,
              Calendar.autoupdatingCurrent.isDate(day, inSameDayAs: model.selectedDate) else {
            return []
        }
        return dayCalendarEvents
    }

    /// 선택한 날의 일정을 불러온다. 구글 계정이 연결돼 있으면 구글에서, 아니면 기기 캘린더에서 읽는다.
    private func loadDayCalendarEvents() async {
        let day = model.selectedDate
        let calendar = Calendar.autoupdatingCurrent
        // 날짜를 바꾼 직후에는 이전 날짜 목록을 즉시 내린다.
        if let loaded = dayCalendarEventsDate, !calendar.isDate(loaded, inSameDayAs: day) {
            dayCalendarEvents = []
            dayCalendarEventsDate = nil
        }
        let (loaded, problem) = await MapHomeDayCalendarLoader.events(on: day, calendar: calendar, service: calendarService)
        // 날짜를 빠르게 넘기면 이전 날짜의 늦은 응답이 올 수 있으므로 지금 날짜와 같을 때만 반영한다.
        guard calendar.isDate(day, inSameDayAs: model.selectedDate) else { return }
        dayCalendarEvents = loaded
        dayCalendarEventsDate = day
        if calendarAccessProblem != problem { calendarAccessProblem = problem }
        if problem == nil { await model.applyDayCalendarEvents(loaded, on: day, fromGoogle: GoogleCalendarAccount.shared.isConnected) }
    }

    /// 메모 목록 패널. 폭은 일정 패널과 같은 280으로 맞춘다.
    private var memoListPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 큐는 3개를 항상 보여 주고, 넘치면 펼침 버튼으로 스크롤 목록을 연다.
            if queueExpanded {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(queuedMemos) { memo in
                            memoCard(memo, showsTime: memo.isTimeless != true)
                        }
                    }
                }
                .frame(maxHeight: 300)
            } else {
                ForEach(queuedMemos.prefix(3)) { memo in
                    memoCard(memo, showsTime: memo.isTimeless != true)
                }
            }
            if queuedMemos.count > 3 {
                Button {
                    withAnimation(.snappy) { queueExpanded.toggle() }
                } label: {
                    Label(
                        queueExpanded ? language.text("접기", "Collapse") : "+\(queuedMemos.count - 3)",
                        systemImage: queueExpanded ? "chevron.up" : "chevron.down"
                    )
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .bold))
                    .foregroundStyle(Color.tpSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .mapHomeGlass(in: Capsule())
                }
                .buttonStyle(.plain)
            }
            if let timed = nearbyTimedMemo {
                memoCard(timed, showsTime: true)
            }
            if let legacy = nearbyScheduleMemo {
                scheduleMemoPreview(legacy)
            }
        }
        .frame(width: 280, alignment: .leading)
    }

    /// 검색(돋보기) 원형 버튼. 누르면 상단 입력창이 펼쳐진다.
    private var searchCircleButton: some View {
        Button {
            // 검색창이 열려 있으면 한 번 더 눌러 닫는다. 다른 곳을 눌러 닫히는 동작은 그대로다.
            if isSearchDismissable {
                withAnimation(.easeInOut(duration: 0.2)) {
                    dismissMapSearchOverlay()
                    isMapSearchFocused = false
                    isSearchExpanded = false
                }
                return
            }
            withAnimation(.easeInOut(duration: 0.2)) {
                isSearchExpanded = true
            }
            // 창이 마운트된 다음 런루프에 포커스를 줘야 @FocusState가 무시되지 않는다.
            DispatchQueue.main.async {
                isMapSearchFocused = true
            }
        } label: {
            TaptionBarIcon(systemImage: "magnifyingglass", size: 25)
                .frame(width: 40, height: 40)
                .background { TaptionStickerDisc() }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(language.text("장소 검색", "Search places"))
    }

    /// 메모를 원형 아이콘 하나로 모은다. 누르면 펼쳐서 목록을 보여 준다.
    private var memoCircleButton: some View {
        // 지금 시각 근처 메모는 그날 메모 목록에도 들어 있으므로 ID로 합쳐 한 번만 센다.
        let count = Set(queuedMemos.map(\.id) + [nearbyTimedMemo?.id].compactMap { $0 }).count
        return Button {
            withAnimation(.snappy) { memoStackExpanded.toggle() }
        } label: {
            TaptionBarIcon(systemImage: memoStackExpanded ? "xmark" : "note.text", size: 25)
                .frame(width: 40, height: 40)
                .background { TaptionStickerDisc() }
                .overlay(alignment: .topTrailing) {
                    if count > 0, !memoStackExpanded {
                        Text("\(count)")
                            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(10)), weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.tpReferenceBlue, in: Capsule())
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(language.text("메모", "Memos"))
    }

    private func memoCard(_ memo: ActionMemo, showsTime: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: showsTime ? "clock.fill" : "note.text")
                .font(.system(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .bold))
                .foregroundStyle(Color.tpReferenceBlue)
                .frame(width: 26, height: 26)
                .background(Color.white.opacity(0.9), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(memo.text)
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .semibold))
                    .foregroundStyle(Color.tpInk)
                    .lineLimit(2)
                if showsTime {
                    Text(memo.occurredAt.formatted(date: .omitted, time: .shortened))
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .semibold))
                        .foregroundStyle(Color.tpSecondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .mapHomeGlass(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { selectedMapStickerEditor = .memo(memo.id) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(language.text("메모 \(memo.text)", "Memo \(memo.text)"))
    }

    /// 새 메모: 먼저 임시 초안을 만들고 편집 화면을 연다. 위치·시간은 편집 화면에서 정한다.
    /// 메모 추가: 시각은 지금, 위치는 현재 위치(없으면 위치 없이). 사용자가 시각을 바꾸고 위치는 뺄 수 있다.
    private func addMemo() {
        isMenuOpen = false
        // 기본 일시는 지금 보고 있는 날짜와 사이드바 시간(날짜를 바꾸거나 사이드바를 옮긴 값)이다.
        let now = timelineSelectionDate
        let here = currentCoordinate.map {
            GeoPoint(latitude: $0.latitude, longitude: $0.longitude, altitude: 0, horizontalAccuracy: 0, verticalAccuracy: 0)
        }
        guard let id = model.addMemoDraft(
            text: language.text("새 메모", "New memo"),
            occurredAt: now,
            mapPoint: here,
            isTimeless: false
        ) else { return }
        selectedMapStickerEditor = .newMemo(id)
    }

    /// 편집 화면에서 "위치 추가": 편집 화면을 닫고 지도에서 핀을 고르게 한 뒤 다시 편집 화면으로 돌아온다.
    private func beginMemoLocationPick(_ id: UUID) {
        pendingMemoLocationID = id
        isMenuOpen = false
        isPlacingMapMemo = true
    }

    private func finishMemoLocationPick(apply: Bool) {
        guard let id = pendingMemoLocationID else { return }
        pendingMemoLocationID = nil
        if apply, let center = mapCenterPoint {
            let point = GeoPoint(
                latitude: center.latitude,
                longitude: center.longitude,
                altitude: 0,
                horizontalAccuracy: 0,
                verticalAccuracy: 0
            )
            if model.isMemoDraft(id) {
                model.updateMemoDraft(id, text: nil, occurredAt: nil, isTimeless: nil, mapPoint: .some(point))
            } else if let memo = model.snapshot.memos.first(where: { $0.id == id }) {
                _ = model.updateMapMemo(
                    id,
                    text: memo.text,
                    kind: memo.kind,
                    mapPoint: point,
                    occurredAt: memo.occurredAt,
                    isTimeless: memo.isTimeless == true
                )
            }
        }
        selectedMapStickerEditor = model.isMemoDraft(id) ? .newMemo(id) : .memo(id)
    }

    /// 위치 고르기: 지도 가운데에 핀을 두고 지도를 움직여 맞춘다. 취소·확인 버튼은 핀 바로 아래에 붙어 함께 떠 있다.
    private var mapMemoPlacementOverlay: some View {
        ZStack {
            VStack {
                Text(language.text("지도를 움직여 핀 위치를 맞추세요", "Move the map to place the pin"))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .semibold))
                    .foregroundStyle(Color.tpInk)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .mapHomeGlass(in: Capsule())
                    .padding(.top, 10)
                    .allowsHitTesting(false)
                Spacer()
            }
            ZStack {
                MapHomePlacementPin()
                    .offset(y: -MapHomePlacementPin.height / 2)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                HStack(spacing: 10) {
                    Button {
                        isPlacingMapMemo = false
                        if pendingMemoLocationID != nil { finishMemoLocationPick(apply: false) }
                    } label: {
                        Text(language.text("취소", "Cancel"))
                            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(14)), weight: .semibold))
                            .foregroundStyle(Color.tpInk)
                            .padding(.horizontal, 18)
                            .frame(minHeight: 40)
                            .mapHomeGlass(in: Capsule())
                    }
                    .buttonStyle(.plain)
                    Button {
                        isPlacingMapMemo = false
                        if pendingMemoLocationID != nil {
                            finishMemoLocationPick(apply: true)
                        } else {
                            addMapMemo()
                        }
                    } label: {
                        Text(pendingMemoLocationID != nil
                             ? language.text("이 위치로", "Use this spot")
                             : language.text("여기에 메모", "Memo here"))
                            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(14)), weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18)
                            .frame(minHeight: 40)
                            .background(Color.tpReferenceBlue, in: Capsule())
                            .shadow(color: Color.tpReferenceBlue.opacity(0.35), radius: 6, y: 2)
                    }
                    .buttonStyle(.plain)
                }
                .offset(y: 34)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func addMapMemo() {
        guard let point = mapCenterPoint else { return }
        addMapMemo(
            at: CLLocationCoordinate2D(
                latitude: point.latitude,
                longitude: point.longitude
            )
        )
    }

    private func addMapMemo(at coordinate: CLLocationCoordinate2D) {
        let point = GeoPoint(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            altitude: 0,
            horizontalAccuracy: 0,
            verticalAccuracy: 0
        )
        // 위치 메모의 기본 일시는 지금 보고 있는 날짜와 사이드바 시간이다.
        let occurredAt = timelineSelectionDate
        let planID = MapMemoLinkEngine
            .plan(containing: occurredAt, in: model.snapshot.plans)?.id
        guard let id = model.addMapMemo(
            text: language.text("새 지도 메모", "New map memo"),
            kind: .idea,
            mapPoint: point,
            planID: planID,
            occurredAt: occurredAt,
            shouldPersist: false
        ) else { return }
        isMenuOpen = false
        selectedMapStickerEditor = .newMemo(id)
    }

    private func runDaySourceTask() async {
        guard model.isBootstrapped, scenePhase == .active else { return }
        let date = model.selectedDate
        guard let prepared = await model.planDaySourceSnapshot(for: date, reusing: dayDataSnapshot),
              !Task.isCancelled, prepared.sourceRevision == model.dayProjectionRevision,
              Calendar.autoupdatingCurrent.isDate(date, inSameDayAs: model.selectedDate) else { return }
        if currentDayDataSnapshot == nil
            || (prepared.isComplete && prepared.sourceRevision != dayDataSnapshot?.sourceRevision) {
            dayDataSnapshot = prepared
            dayDataIsPreview = !prepared.isComplete
            reportInitialMapShellReadyIfNeeded(for: model.selectedDate)
        }
        routeActualIndex = nil
        refreshHomeGrowth(at: .now)
        refreshTimeRailSegments()
        requestRouteProjectionRefresh(preparingReadings: true)
        requestWBSPlaybackProjectionRefresh()
        scheduleExpectedRouteRefresh()
            }

    private func runRouteReadingsTask() async {
        guard model.isBootstrapped || model.hasPreparedStartupSettings,
              scenePhase == .active else { return }
        let loadStartedAt = ProcessInfo.processInfo.systemUptime
        let date = model.selectedDate
        if !routeReadingsLoadState.isLoaded(for: date) {
            routeReadingsLoadState = .loading(
                MapHomeRouteReadingsPolicy.dayKey(for: date)
            )
        }
        applyInitialMapFocusIfNeeded()
        reportInitialMapShellReadyIfNeeded(for: date)
        await Task.yield()
        if let preview = await model.startupDayDataPreview(for: date) {
            await refreshRouteReadings(for: date, preloadedDayData: preview, isPreview: true)
        }
        await model.prepareLocalDataForDisplay()
        guard !Task.isCancelled, scenePhase == .active,
              Calendar.autoupdatingCurrent.isDate(date, inSameDayAs: model.selectedDate)
        else { return }
        if let cached = await model.cachedPlanDayDataSnapshot(for: date) {
            await refreshRouteReadings(
                for: date,
                preloadedDayData: cached,
                isPreview: true
            )
            guard !Task.isCancelled,
                  Calendar.autoupdatingCurrent.isDate(date, inSameDayAs: model.selectedDate)
            else { return }
            TaptionPlanDiagnosticsLogger.shared.record(
                "map_cached_projection_ready",
                fields: ["duration_ms": String(Int((
                    ProcessInfo.processInfo.systemUptime - loadStartedAt
                ) * 1_000))]
            )
        }
        guard !Task.isCancelled else { return }
        async let dayData = model.planDayDataSnapshot(
            for: date,
            forceReload: false,
            refreshRawReadings: true
        )
        prepareRouteProjectionReadings()
        refreshRouteProjection()
        focusMapIfNeeded()
        refreshTimeRailSegments()
        let mapCacheStartedAt = ProcessInfo.processInfo.systemUptime
        let cachedMapDay = await loadMapDayCache(for: date)
        let mapCacheDuration = ProcessInfo.processInfo.systemUptime
            - mapCacheStartedAt
        applyInitialMapFocusIfNeeded()
        guard !Task.isCancelled,
              Calendar.autoupdatingCurrent.isDate(
                  date,
                  inSameDayAs: model.selectedDate
              ) else { return }
        refreshTimeRailSegments()
        let snapshotWaitStartedAt = ProcessInfo.processInfo.systemUptime
        await refreshRouteReadings(
            for: date,
            preloadedDayData: await dayData,
            cachedMapDay: cachedMapDay
        )
        TaptionPlanDiagnosticsLogger.shared.record(
            "map_date_load_finished",
            fields: [
                "duration_ms": String(Int((
                    ProcessInfo.processInfo.systemUptime - loadStartedAt
                ) * 1_000)),
                "map_cache_ms": String(Int(mapCacheDuration * 1_000)),
                "snapshot_wait_ms": String(Int((
                    ProcessInfo.processInfo.systemUptime - snapshotWaitStartedAt
                ) * 1_000)),
            ]
        )
        applyInitialMapFocusIfNeeded()
            }

    /// `body`의 수정자 체인이 길어 타입 검사가 느려지지 않도록 `.task`의 id를 따로 계산한다.
    private var daySourceTaskKey: MapHomeDaySourceTaskKey {
        MapHomeDaySourceTaskKey(
            day: Calendar.autoupdatingCurrent.startOfDay(for: model.selectedDate),
            revision: model.dayProjectionRevision,
            isReady: model.isBootstrapped,
            isActive: scenePhase == .active
        )
    }

    private var routeReadingsTaskKey: MapHomeRouteReadingsTaskKey {
        let date = model.selectedDate
        let isToday = Calendar.autoupdatingCurrent.isDateInToday(date)
        let rawRevision: UInt64 = isToday ? 0 : model.rawDataRevision(for: date)
        return MapHomeRouteReadingsTaskKey(
            date: date,
            isBootstrapped: model.isBootstrapped || model.hasPreparedStartupSettings,
            rawDataRevision: rawRevision,
            isSceneActive: scenePhase == .active
        )
    }

    /// Map Home이 실제로 MapLibre 벡터 렌더러로 그려지는지(= Apple 스타일이 아님).
    /// 카메라 이동 명령 경로를 실제 렌더 엔진에 맞춰 고르는 데 쓴다.
    private var rendersVectorMap: Bool {
        model.settings.mapDisplayStyle.runtimeStyle.mapHomeVectorStyle != nil
    }

    private var vectorMapContentInsets: UIEdgeInsets {
        .zero
    }

    private func vectorMap(style: MapHomeVectorStyle) -> some View {
        let cameraRevision = mapCameraRevision
        let waypoints = pawprintWaypoints
        // 오버레이는 이 순서(예상 경로 먼저, 그다음 번호순)로 그린다. 프레임마다 정렬하지 않게 한 번만 정렬한다.
        let drawOrderWaypoints = waypoints.sorted {
            $0.isPredicted != $1.isPredicted ? $0.isPredicted : $0.index < $1.index
        }
        let inputs = mapOverlayInputs()
        let places = inputs.places
        let playback = appleMapPlayback
        let displayedSpeed = displayedSpeedMetersPerSecond
        let activeSegments = vectorActiveRouteSegments
        return MapHomeVectorMap(
            style: style,
            cameraPosition: mapPosition,
            cameraRevision: mapCameraRevision,
            historicalRoutes: recordingShows(\.routes) ? vectorHistoricalRoutes : [],
            activeRoute: recordingShows(\.routes) && activeSegments.isEmpty ? vectorActiveRoute : nil,
            expectedRoutes: recordingShows(\.routes) ? vectorExpectedRoutes : [],
            subwayRoutes: recordingShows(\.routes) ? vectorSubwayRoutes + vectorUserSelectedRoutes : [],
            markers: vectorMapMarkers(waypoints: waypoints, inputs: inputs),
            contentInsets: vectorMapContentInsets,
            longPressExclusionFrame: isMenuOpen ? .zero : mapControlsFrame,
            followsHeading: isHeadingMode && userTrackingMode.keepsCameraLocked,
            headingDegrees: -compassRotationDegrees,
            displayedCoordinate: displayedLocationCoordinate,
            easesCamera: isDayPlaybackRunning,
            playbackDriver: playbackDriver,
            onPlaybackStickmanPoint: { point in
                vectorMapViewportStore.publishPlaybackPoint(point, nowUptime: ProcessInfo.processInfo.systemUptime)
            },
            onPlaybackViewport: { viewport in
                vectorMapViewportStore.livePlaybackViewport = viewport
            },
            onViewportChange: { viewport, isFinal in
                guard cameraRevision == mapCameraRevision else { return }
                applyVectorMapViewport(viewport, isFinal: isFinal)
            },
            onSingleFingerPanBegan: handleUserMapPan,
            onSingleFingerPanEnded: finishDisplayedStickmanViewportProjection,
            onUserCameraGesture: handleUserCameraGesture,
            onLongPress: presentMapLongPressMenu,
            onSingleTap: { point, positions in
                handleMapTap(atLocal: point, waypoints: waypoints, positions: positions)
            },
            activeRouteSegments: recordingShows(\.routes) ? activeSegments : []
        )
        .id(style.rawValue)
        .overlay {
            if !Self.benchHidden("overlay") {
            MapHomeVectorViewportOverlay(store: vectorMapViewportStore, isLive: playbackDriver != nil) {
                viewport, stickmanPoint in
                vectorMapAnnotationOverlay(
                    style: style,
                    viewport: viewport,
                    stickmanPoint: stickmanPoint,
                    waypoints: drawOrderWaypoints,
                    inputs: inputs,
                    playback: playback,
                    displayedSpeed: displayedSpeed
                )
            }
            }
        }
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named("mapHomeViewport")) }) { frame in
            if mapFrameInViewport != frame { mapFrameInViewport = frame }
        }
        .task {
            applyInitialLocationIfAvailable(using: nil)
            beginInitialLocationRequest(using: nil)
        }
        .onChange(of: mapViewportSize) { _, size in
            guard size.width > 0, size.height > 0 else { return }
            applyInitialLocationIfAvailable(using: nil)
            beginInitialLocationRequest(using: nil)
        }
        .onChange(of: selectedTimelineMinute) { _, minute in
            if isTimelineInteractionActive || isDayPlaybackRunning {
                let interval = isDayPlaybackRunning
                    ? MapHomeDayPlaybackMath.mapFocusInterval
                    : TimelineInteractionFrameGate.minimumInterval
                let now = ProcessInfo.processInfo.systemUptime
                let shouldFocus: Bool
                if isDayPlaybackRunning {
                    shouldFocus = !isPlaybackIntroActive && TimelineInteractionFrameGate.shouldRender(
                        lastUptime: &lastPlaybackMapFocusUptime,
                        nowUptime: now,
                        minimumInterval: interval
                    )
                } else {
                    shouldFocus = TimelineInteractionFrameGate.shouldRender(
                        lastUptime: &lastTimelineMapFocusUptime,
                        nowUptime: now,
                        minimumInterval: interval
                    )
                }
                guard shouldFocus, playbackDriver == nil else { return }
                guard let point = displayedPlaybackFocusPoint else { return }
                focusMap(on: point, using: nil, followsTracking: true)
            } else {
                refreshSelectedTimelineMapPosition(minute: minute, using: nil)
            }
        }
        .onChange(of: dayPlaybackCurrentMinute) { _, _ in
            // 벡터 지도에서는 구동기가 프레임마다 카메라를 놓는다(PLY1029A03). 여기는 Apple 지도 재생용이다.
            guard isDayPlaybackRunning, playbackDriver == nil,
                  TimelineInteractionFrameGate.shouldRender(
                      lastUptime: &lastPlaybackMapFocusUptime,
                      nowUptime: ProcessInfo.processInfo.systemUptime,
                      minimumInterval: MapHomeDayPlaybackMath.mapFocusInterval
                  ) else { return }
            recordPlaybackFocusSample()
            guard let point = displayedPlaybackFocusPoint else { return }
            focusMap(on: point, using: nil, followsTracking: true)
        }
        .onChange(of: isTimelineInteractionActive) { _, isInteracting in
            guard !isInteracting, !isDayPlaybackRunning,
                  selectedTimelineMinute != nil else { return }
            refreshSelectedTimelineMapPosition(
                minute: selectedTimelineMinute,
                using: nil
            )
            finishDisplayedStickmanViewportProjection()
        }
        .onChange(of: model.latestSensorReading?.id) { _, _ in
            applyInitialLocationIfAvailable(using: nil)
            guard MapHomeUserTrackingPolicy.focusesLocationUpdates(
                in: userTrackingMode
            ) else { return }
            focusDisplayedLocation(using: nil)
        }
        .onChange(of: model.liveRouteState.readings.last?.id) { _, _ in
            guard MapHomeUserTrackingPolicy.focusesLocationUpdates(
                in: userTrackingMode
            ) else { return }
            focusDisplayedLocation(using: nil)
        }
    }


    /// 벡터 지도 `MapHomeFogLayer`와 같은 걷어낼 지점(발자국·장소 72pt, 현재 위치 96pt).
    private var appleFogReveals: [MapHomeFogReveal]? {
        guard fogStrength != .off else { return nil }
        let radius = MapHomeFogStrength.revealRadius
        var reveals = playbackVisibleWaypoints(pawprintWaypoints).map { MapHomeFogReveal(coordinate: $0.coordinate, radius: radius) }
        reveals += placeAnnotations.map { MapHomeFogReveal(coordinate: $0.coordinate, radius: radius) }
        if let displayed = displayedLocationCoordinate {
            reveals.append(MapHomeFogReveal(coordinate: displayed, radius: MapHomeFogStrength.currentLocationRadius))
        }
        return reveals
    }

    private var mapKitMap: some View {
        MapHomeAppleMap(
            style: model.settings.mapDisplayStyle.runtimeStyle,
            accessibilityLabel: language.text("Apple 지도", "Apple map"),
            cameraPosition: mapPosition,
            cameraRevision: mapCameraRevision,
            viewportCommand: appleViewportCommand,
            routes: recordingShows(\.routes) ? appleMapRoutes : [],
            annotations: appleMapAnnotations,
            playback: appleMapPlayback,
            centersPlayback: selectedTimelineMinute != nil
                || isTimelineInteractionActive
                || userTrackingMode.keepsCameraLocked,
            playbackTargetPoint: currentLocationTargetPoint,
            playbackDriver: playbackDriver,
            contentInsets: vectorMapContentInsets,
            longPressExclusionFrame: isMenuOpen ? .zero : mapControlsFrame,
            fogReveals: appleFogReveals,
            fogOpacity: CGFloat(fogStrength.opacity),
            onLiveStickmanPoint: { appleStickmanLivePoint.point = $0 },
            counterAttachment: appleStickmanLivePoint.markerAttachment,
            onCameraFrame: { frame, locationPoint, isFinal in
                MapHomeHomeSkyHeading.current = frame.camera.heading
                MapHomeInteractionMonitor.shared.touch("map_gesture")
                let now = ProcessInfo.processInfo.systemUptime
                let moving = !isFinal || playbackDriver != nil
                if isAppleCameraMoving != moving { isAppleCameraMoving = moving }
                if let rendered = mapCameraFrameProjection.submit(
                    frame,
                    nowUptime: now,
                    force: isFinal
                ), mapCameraFrameProjection.shouldPublishParentReadback(
                    nowUptime: now,
                    isFinal: isFinal
                ) {
                    applyMapCameraFrame(rendered, locationPoint: locationPoint)
                }
                // 손을 뗀 마지막 점은 입력 예산에 걸려도 버리지 않는다(탭 판정·안개 기준).
                if isFinal, playbackDriver == nil {
                    finishDisplayedStickmanViewportProjection()
                }
            },
            onSingleFingerPanBegan: handleUserMapPan,
            onUserCameraGesture: handleUserCameraGesture,
            onLongPress: presentMapLongPressMenu,
            onAnnotationSelected: handleAppleMapAnnotation,
            onMapTap: { local, hitsWalker in
                if hitsWalker { presentDaySummary(fromCat: true) }
                handleMapTap(atLocal: local, waypoints: pawprintWaypoints, positions: nil)
            }
        )
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named("mapHomeViewport")) }) { frame in
            if mapFrameInViewport != frame { mapFrameInViewport = frame }
        }
        .task {
            applyInitialLocationIfAvailable(using: nil)
            beginInitialLocationRequest(using: nil)
        }
        .onChange(of: mapViewportSize) { _, size in
            guard size.width > 0, size.height > 0 else { return }
            applyInitialLocationIfAvailable(using: nil)
            beginInitialLocationRequest(using: nil)
        }
        .onChange(of: headingMonitor.headingDegrees) { _, _ in
            applyMapHeading(using: nil)
        }
        .onChange(of: dayPlaybackCurrentMinute) { _, _ in
            advanceApplePlaybackZoom()
        }
        .onChange(of: isTimelineInteractionActive) { _, isInteracting in
            guard !isInteracting else { return }
            flushDeferredWBSPlaybackProjection()
            finishDisplayedStickmanViewportProjection()
        }
        .onChange(of: model.latestSensorReading?.id) { _, _ in
            applyInitialLocationIfAvailable(using: nil)
            guard MapHomeUserTrackingPolicy.focusesLocationUpdates(
                in: userTrackingMode
            ) else { return }
            focusDisplayedLocation(using: nil)
        }
        .onChange(of: model.liveRouteState.readings.last?.id) { _, _ in
            guard MapHomeUserTrackingPolicy.focusesLocationUpdates(
                in: userTrackingMode
            ) else { return }
            focusDisplayedLocation(using: nil)
        }
    }

    private var vectorHistoricalRoutes: [MapHomeVectorRoute] {
        timelineRouteOverlays.dropLast().flatMap { overlay in
            vectorRoutes(for: overlay, idPrefix: "")
        }
    }

    /// 실제 경로를 속도 그라데이션 구간으로 나눈다. 속도를 모르면 기존 단색 한 줄이다.
    private func vectorRoutes(
        for overlay: MapHomeTimelineRouteOverlay,
        idPrefix: String
    ) -> [MapHomeVectorRoute] {
        let opacity = MapHomeWBSTripStyle.actualRouteOpacity
            * min(max(overlay.opacity, 0), 1)
        guard let slices = mapRenderCache.gradientSlices(
            id: overlay.id,
            coordinates: overlay.coordinates,
            geometrySignature: overlay.geometrySignature,
            timestamps: overlay.coordinateTimestamps
        ) else {
            return [
                MapHomeVectorRoute(
                    id: idPrefix + overlay.id,
                    coordinates: overlay.coordinates,
                    geometrySignature: overlay.geometrySignature,
                    colorHex: MapHomeWBSTripStyle.actualRouteHex,
                    opacity: opacity
                )
            ]
        }
        return slices.map { slice in
            MapHomeVectorRoute(
                id: idPrefix + slice.id,
                coordinates: slice.coordinates,
                geometrySignature: slice.geometrySignature,
                colorHex: slice.colorHex,
                opacity: opacity
            )
        }
    }

    private var appleActualRoutes: [MapHomeAppleRoute] {
        timelineRouteOverlays.flatMap { overlay -> [MapHomeAppleRoute] in
            let opacity = MapHomeWBSTripStyle.actualRouteOpacity
                * min(max(overlay.opacity, 0), 1)
            guard let slices = mapRenderCache.gradientSlices(
                id: overlay.id,
                coordinates: overlay.coordinates,
                geometrySignature: overlay.geometrySignature,
                timestamps: overlay.coordinateTimestamps
            ) else {
                return [
                    MapHomeAppleRoute(
                        id: "timeline-\(overlay.id)",
                        coordinates: overlay.coordinates,
                        geometrySignature: overlay.geometrySignature,
                        colorHex: MapHomeWBSTripStyle.actualRouteHex,
                        opacity: opacity,
                        phase: .actual,
                        transport: nil
                    )
                ]
            }
            return slices.map { slice in
                MapHomeAppleRoute(
                    id: "timeline-\(slice.id)",
                    coordinates: slice.coordinates,
                    geometrySignature: slice.geometrySignature,
                    colorHex: slice.colorHex,
                    opacity: opacity,
                    phase: .actual,
                    transport: nil
                )
            }
        }
    }

    private var appleMapRoutes: [MapHomeAppleRoute] {
        var routes = appleActualRoutes

        routes += subwayRouteOverlays.compactMap { overlay in
            guard overlay.coordinates.count >= 2 else { return nil }
            return MapHomeAppleRoute(
                id: "subway-\(overlay.id.uuidString)",
                coordinates: overlay.coordinates,
                geometrySignature: overlay.geometrySignature,
                colorHex: MapHomeWBSTripStyle.transitRouteHex,
                opacity: overlay.estimated
                    ? MapHomeWBSTripStyle.forecastRouteOpacity
                    : MapHomeWBSTripStyle.actualRouteOpacity,
                phase: overlay.estimated ? .forecast : .actual,
                transport: .transit
            )
        }

        routes += appleMapForecastRoutes
        routes += appleUserSelectedRoutes
        return routes.filter { $0.coordinates.count >= 2 }
    }

    /// 사용자가 확정한 예상 경로와 지금 선택한 예상 경로의 선. 발자국이 이 경로 위에 그려지므로 선도 같은 좌표로 그린다
    /// (벡터 지도의 `vectorUserSelectedRoutes`와 같은 내용).
    private var appleUserSelectedRoutes: [MapHomeAppleRoute] {
        var routes = confirmedPredictedRoutes.map { route -> MapHomeAppleRoute in
            let points = coordinates(for: route, through: routeOverlayCutoff)
            return MapHomeAppleRoute(
                id: "confirmed-predicted-\(route.id)",
                coordinates: points,
                geometrySignature: MapHomeRouteGeometrySignature.value(for: points),
                colorHex: MapHomeWBSTripStyle.actualRouteHex,
                opacity: 0.95,
                phase: .actual,
                transport: nil
            )
        }
        if let selectedPredictedRoute {
            let points = coordinates(for: selectedPredictedRoute)
            routes.append(MapHomeAppleRoute(
                id: "selected-\(selectedPredictedRoute.id)",
                coordinates: points,
                geometrySignature: MapHomeRouteGeometrySignature.value(for: points),
                colorHex: "#FF9800",
                opacity: 1,
                phase: .actual,
                transport: nil
            ))
        }
        return routes
    }

    private var appleMapForecastRoutes: [MapHomeAppleRoute] {
        let expected = displayedExpectedRouteOverlays
        let generated = displayedWBSGeneratedRouteOverlays
        let fallback = expected.map { overlay in
            MapHomeAppleRoute(
                id: "expected-\(overlay.id.uuidString)",
                coordinates: overlay.coordinates,
                geometrySignature: overlay.geometrySignature,
                colorHex: MapHomeAppleRouteTransport(mode: overlay.mode)
                    .forecastColorHex,
                opacity: MapHomeWBSTripStyle.forecastRouteOpacity,
                phase: .forecast,
                transport: MapHomeAppleRouteTransport(mode: overlay.mode)
            )
        } + generated.map { overlay in
            MapHomeAppleRoute(
                id: "wbs-\(overlay.id)",
                coordinates: overlay.coordinates,
                geometrySignature: overlay.geometrySignature,
                colorHex: overlay.mode.map {
                    MapHomeAppleRouteTransport(mode: $0).forecastColorHex
                } ?? MapHomeWBSTripStyle.forecastRouteHex,
                opacity: MapHomeWBSTripStyle.forecastRouteOpacity,
                phase: .forecast,
                transport: overlay.mode.map { MapHomeAppleRouteTransport(mode: $0) }
            )
        }
        guard let projection = wbsPlaybackProjection else { return fallback }
        let expectedLegIDs = Set(expected.map { "movement-\($0.id.uuidString)" })
        let generatedLegIDs = Set(generated.map(\.id))
        let dottedLegIDs = expectedLegIDs.union(generatedLegIDs)
        let baseSignatures = Dictionary(
            fallback.map { ($0.id, $0.geometrySignature) },
            uniquingKeysWith: { first, _ in first }
        )
        let cutoff = routeOverlayCutoff
        let projected = projection.legs.compactMap { leg -> MapHomeAppleRoute? in
            guard dottedLegIDs.contains(leg.id),
                  leg.routePhase == .forecast,
                  leg.activity == .movement,
                  let coordinates = visibleForecastCoordinates(
                    for: leg,
                    through: cutoff
                  ) else { return nil }
            let id: String
            if expectedLegIDs.contains(leg.id) {
                id = "expected-\(String(leg.id.dropFirst("movement-".count)))"
            } else {
                id = "wbs-\(leg.id)"
            }
            guard let baseSignature = baseSignatures[id] else { return nil }
            return MapHomeAppleRoute(
                id: id,
                coordinates: coordinates,
                geometrySignature: MapHomeRouteGeometrySignature.derived(
                    from: baseSignature,
                    coordinates: coordinates
                ),
                colorHex: leg.mode.map {
                    MapHomeAppleRouteTransport(mode: $0).forecastColorHex
                } ?? MapHomeWBSTripStyle.forecastRouteHex,
                opacity: MapHomeWBSTripStyle.forecastRouteOpacity,
                phase: .forecast,
                transport: leg.mode.map { MapHomeAppleRouteTransport(mode: $0) }
            )
        }
        return projected
    }

    private func visibleForecastCoordinates(
        for leg: MapHomeWBSPlaybackLeg,
        through cutoff: Date
    ) -> [CLLocationCoordinate2D]? {
        guard cutoff > leg.startDate,
              leg.coordinates.count >= 2 else { return nil }
        let coordinates = leg.coordinates.map {
            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
        }
        guard cutoff < leg.endDate else { return coordinates }
        let duration = leg.endDate.timeIntervalSince(leg.startDate)
        guard duration > 0 else { return coordinates }
        let fraction = min(
            max(cutoff.timeIntervalSince(leg.startDate) / duration, 0),
            1
        )
        return MapHomeExpectedRouteOverlay.prefixByDistance(
            coordinates,
            fraction: fraction,
            segmentLengths: leg.segmentLengths
        )
    }

    private var appleMapAnnotations: [MapHomeAppleAnnotation] {
        let probe = MapHomePlaybackProbe.begin("apple.annotationsBuild"); defer { MapHomePlaybackProbe.end(probe) }
        var annotations = temporaryLocationAnnotations.map { location in
            MapHomeAppleAnnotation(
                id: "temporary-\(location.id.uuidString)",
                coordinate: location.coordinate,
                kind: .temporary(
                    stationName: location.stationName,
                    title: language.text("임시 위치", "Temporary")
                ),
                accessibilityLabel: language.text(
                    "\(location.stationName) 지하철 임시 위치",
                    "\(location.stationName) temporary subway location"
                ),
                isInteractive: false
            )
        }
        annotations += (recordingShows(\.placeIcons) ? placeAnnotations : []).map { place in
            MapHomeAppleAnnotation(
                id: "place-\(place.id.uuidString)",
                coordinate: place.coordinate,
                kind: .place(place),
                accessibilityLabel: place.destination == .user
                    ? language.text(
                        "\(place.name) 사용자 위치 메뉴",
                        "\(place.name) user location menu"
                    )
                    : language.text(
                        "\(place.name), 레벨 \(place.floor ?? 1)",
                        "\(place.name), level \(place.floor ?? 1)"
                    ),
                isInteractive: place.destination == .user
            )
        }
        annotations += transitAnnotations.map { place in
            MapHomeAppleAnnotation(
                id: "transit-\(place.id.uuidString)",
                coordinate: place.coordinate,
                kind: .transit(place),
                accessibilityLabel: language.text(
                    "\(place.name) 사용자 위치 메뉴",
                    "\(place.name) user location menu"
                ),
                isInteractive: true
            )
        }
        annotations += transitBoardingCandidates.map { candidate in
            MapHomeAppleAnnotation(
                id: "boarding-\(candidate.id)",
                coordinate: CLLocationCoordinate2D(
                    latitude: candidate.point.latitude,
                    longitude: candidate.point.longitude
                ),
                kind: .boarding(candidate),
                accessibilityLabel: language.text(
                    "\(candidate.name) \(candidate.kind.title) 탑승 확인",
                    "Confirm boarding at \(candidate.name) \(candidate.kind.englishTitle)"
                ),
                isInteractive: true
            )
        }
        annotations += mapStickersOnMap.compactMap { sticker in
            guard let point = sticker.point else { return nil }
            return MapHomeAppleAnnotation(
                id: "sticker-\(sticker.id.uuidString)",
                coordinate: CLLocationCoordinate2D(
                    latitude: point.latitude,
                    longitude: point.longitude
                ),
                kind: .sticker(sticker),
                accessibilityLabel: language.text(
                    "\(sticker.title) 메모 스티커",
                    "\(sticker.title) memo sticker"
                ),
                isInteractive: isStickerMode
            )
        }
        annotations += mapMemosOnMap.compactMap { memo in
            guard let point = memo.mapPoint else { return nil }
            return MapHomeAppleAnnotation(
                id: "memo-\(memo.id.uuidString)",
                coordinate: CLLocationCoordinate2D(
                    latitude: point.latitude,
                    longitude: point.longitude
                ),
                kind: .memo(memo),
                accessibilityLabel: language.text(
                    "\(memo.text) 지도 메모, \(memo.occurredAt.formatted(date: .omitted, time: .shortened))",
                    "\(memo.text) map memo, \(memo.occurredAt.formatted(date: .omitted, time: .shortened))"
                ),
                isInteractive: true
            )
        }
        if let selectedSearchPin {
            annotations.append(
                MapHomeAppleAnnotation(
                    id: "search-pin",
                    coordinate: selectedSearchPin.coordinate,
                    kind: .search(selectedSearchPin),
                    accessibilityLabel: language.text(
                        "\(selectedSearchPin.title) 위치 추가",
                        "Add \(selectedSearchPin.title) location"
                    ),
                    isInteractive: true
                )
            )
        }
        for waypoint in playbackVisibleWaypoints(recordingShows(\.footprints) ? pawprintWaypoints : []).suffix(300) {
            let isSelectedRoute = waypoint.isPredicted && waypoint.predictedRoute != nil
                && waypoint.predictedRoute?.id == selectedPredictedRoute?.id
            let isInteractive = waypoint.predictedRoute != nil
                || (waypoint.timestamp != nil && !waypoint.isPredicted)
            annotations.append(
                MapHomeAppleAnnotation(
                    id: vectorPawprintMarkerID(waypoint.index),
                    coordinate: waypoint.coordinate,
                    kind: .pawprint(MapHomeApplePawprint(
                        index: waypoint.index, angle: waypoint.angle,
                        isPredicted: waypoint.isPredicted, isSelectedRoute: isSelectedRoute,
                        speedMetersPerSecond: waypoint.speedMetersPerSecond
                    )),
                    accessibilityLabel: waypoint.predictedRoute != nil
                        ? language.text("예상 경로 선택", "Select predicted route")
                        : waypoint.timestamp.map {
                            language.text("기록 발자국 ", "Recorded paw ")
                                + $0.formatted(date: .omitted, time: .shortened)
                        } ?? "",
                    isInteractive: isInteractive
                )
            )
        }
        return annotations
    }

    private var appleMapPlayback: MapHomeApplePlayback? {
        guard !isDisplayedCatAtHome,
              let coordinate = displayedLocationCoordinate else { return nil }
        let heading: CLLocationDirection
        let phase: MapHomeAppleRoutePhase
        let animationPhase: Int?
        let cameraCoordinate: CLLocationCoordinate2D
        if selectedPawprintPoint != nil {
            heading = CLLocationDirection(wbsPlaybackFrame?.direction.rawValue ?? 0) * 45
            phase = .actual
            animationPhase = wbsPlaybackFrame?.stickmanFrameIndex
            cameraCoordinate = coordinate
        } else if let frame = wbsPlaybackFrame {
            heading = CLLocationDirection(frame.direction.rawValue * 45)
            phase = frame.routePhase == .actual ? .actual : .forecast
            animationPhase = frame.stickmanFrameIndex
            cameraCoordinate = CLLocationCoordinate2D(
                latitude: frame.cameraCoordinate.latitude,
                longitude: frame.cameraCoordinate.longitude
            )
        } else if let route = activeExpectedRoute {
            heading = MapHomeApplePlaybackMath.heading(
                at: displayedLocationDate,
                departureDate: route.departureDate,
                arrivalDate: route.arrivalDate,
                coordinates: route.coordinates,
                segmentLengths: route.segmentLengths
            )
            phase = .forecast
            animationPhase = MapHomeExpectedRoutePlaybackMath.progress(
                at: displayedLocationDate,
                departureDate: route.departureDate,
                arrivalDate: route.arrivalDate
            ).map(MapHomeStickmanAnimationEngine.phase(for:))
            cameraCoordinate = coordinate
        } else {
            heading = MapHomeApplePlaybackMath.stableHeading(
                MapHomePlaybackLocation.gapHeading(at: displayedLocationDate, travel: currentDayDataSnapshot?.travel ?? [], readings: historicalPlaybackReadings)
                    ?? MapHomeApplePlaybackMath.heading(
                    at: displayedLocationDate,
                    readings: historicalPlaybackReadings
                ) ?? model.latestSensorReading?.courseDegrees
                    ?? headingMonitor.headingDegrees
                    ?? 0
            )
            phase = .actual
            animationPhase = routeProjection.flatMap {
                MapHomeRouteTimelinePlaybackMath.progress(
                    at: displayedLocationDate,
                    in: $0.segments
                )
            }.map(MapHomeStickmanAnimationEngine.phase(for:))
            cameraCoordinate = coordinate
        }
        let action = displayedStickmanAction
        return MapHomeApplePlayback(
            coordinate: coordinate,
            cameraCoordinate: cameraCoordinate,
            headingDegrees: heading,
            action: action,
            accessibilityLabel: "\(displayedLocationAccessibilityLabel) · \(action.title)",
            phase: phase,
            followsUserLocation: selectedTimelineMinute == nil,
            equippedAccessoryID: homeGrowthHistory.season.equippedAccessory,
            stickmanAnimationPhase: selectedTimelineMinute == nil
                ? nil
                : animationPhase
        )
    }

    private func handleAppleMapAnnotation(_ kind: MapHomeAppleAnnotationKind) {
        switch kind {
        case .temporary:
            break
        case .place(let place):
            if place.destination == .home {
                isDaySummaryPresented = true
                return
            }
            guard place.destination == .user else { return }
            selectedUserLocation = .frequentPlace(place.id)
        case .transit(let place):
            selectedUserLocation = .transit(place.id)
        case .boarding(let candidate):
            selectedTransitBoardingCandidate = candidate
        case .sticker(let sticker):
            selectedMapStickerEditor = .sticker(sticker.id)
        case .memo(let memo):
            selectedMapStickerEditor = .memo(memo.id)
        case .search:
            isSearchPinMenuPresented = true
        case .pawprint(let paw):
            if let waypoint = pawprintWaypoints.first(where: { $0.index == paw.index }) {
                selectPawprint(waypoint)
            }
        }
    }

    private var vectorActiveRouteSegments: [MapHomeVectorRoute] {
        guard let overlay = timelineRouteOverlays.last else { return [] }
        let routes = vectorRoutes(for: overlay, idPrefix: "active-")
        return routes.count == 1 && routes[0].id == "active-" + overlay.id
            ? [] : routes
    }

    private var vectorActiveRoute: MapHomeVectorRoute? {
        guard let overlay = timelineRouteOverlays.last else { return nil }
        return MapHomeVectorRoute(
            id: "active-\(overlay.id)",
            coordinates: overlay.coordinates,
            geometrySignature: overlay.geometrySignature,
            colorHex: MapHomeWBSTripStyle.actualRouteHex,
            opacity: MapHomeWBSTripStyle.actualRouteOpacity
                * min(max(overlay.opacity, 0), 1)
        )
    }

    private var vectorExpectedRoutes: [MapHomeVectorRoute] {
        let expected = displayedExpectedRouteOverlays.map { overlay in
            MapHomeVectorRoute(
                id: "expected-\(overlay.id.uuidString)",
                coordinates: overlay.coordinates,
                geometrySignature: overlay.geometrySignature,
                colorHex: MapHomeAppleRouteTransport(mode: overlay.mode)
                    .forecastColorHex,
                opacity: MapHomeWBSTripStyle.forecastRouteOpacity
            )
        }
        let generated = displayedWBSGeneratedRouteOverlays.map { overlay in
            MapHomeVectorRoute(
                id: "wbs-\(overlay.id)",
                coordinates: overlay.coordinates,
                geometrySignature: overlay.geometrySignature,
                colorHex: overlay.mode.map {
                    MapHomeAppleRouteTransport(mode: $0).forecastColorHex
                } ?? MapHomeWBSTripStyle.forecastRouteHex,
                opacity: MapHomeWBSTripStyle.forecastRouteOpacity
            )
        }
        let estimatedSubway: [MapHomeVectorRoute] = subwayRouteOverlays.compactMap {
            overlay -> MapHomeVectorRoute? in
            guard overlay.estimated,
                  predictedRoute(for: overlay).map({ !hasRouteDecision($0) }) ?? true else { return nil }
            return MapHomeVectorRoute(
                id: "subway-estimated-\(overlay.id)",
                coordinates: overlay.coordinates,
                geometrySignature: overlay.geometrySignature,
                colorHex: MapHomeWBSTripStyle.transitRouteHex,
                opacity: MapHomeWBSTripStyle.forecastRouteOpacity
            )
        }
        return expected + generated + estimatedSubway
    }

    private var vectorSubwayRoutes: [MapHomeVectorRoute] {
        subwayRouteOverlays.compactMap { overlay in
            guard !overlay.estimated,
                  predictedRoute(for: overlay).map({ !hasRouteDecision($0) }) ?? true else { return nil }
            return MapHomeVectorRoute(
                id: "subway-\(overlay.id)",
                coordinates: overlay.coordinates,
                geometrySignature: overlay.geometrySignature,
                colorHex: MapHomeWBSTripStyle.transitRouteHex,
                opacity: MapHomeWBSTripStyle.actualRouteOpacity
            )
        }
    }

    /// 지도 위 표시에 쓰는 값을 화면 갱신마다 한 번만 계산한다. 마커 목록과 60Hz 오버레이가 같은 값을 쓴다
    /// (성능 리뷰: 오버레이가 매 프레임 계산 프로퍼티를 다시 읽던 낭비).
    private func mapOverlayInputs() -> MapHomeOverlayInputs {
        MapHomeOverlayInputs(
            places: recordingShows(\.placeIcons) ? placeAnnotations : [],
            temporaryLocations: temporaryLocationAnnotations,
            transit: transitAnnotations,
            boarding: transitBoardingCandidates,
            stickers: mapStickersOnMap,
            photos: photoClusters,
            memos: recordingShows(\.mapMemos) ? mapMemosOnMap : []
        )
    }

    private func vectorMapMarkers(waypoints: [PawprintWaypoint], inputs: MapHomeOverlayInputs) -> [MapHomeVectorMarker] {
        let probe = MapHomePlaybackProbe.begin("vectorMapMarkers"); defer { MapHomePlaybackProbe.end(probe) }
        var markers = inputs.temporaryLocations.map {
            MapHomeVectorMarker(
                id: vectorTemporaryMarkerID($0.id),
                coordinate: $0.coordinate
            )
        }
        markers += inputs.places.map {
            MapHomeVectorMarker(
                id: vectorPlaceMarkerID($0.id),
                coordinate: $0.coordinate
            )
        }
        markers += inputs.transit.map {
            MapHomeVectorMarker(
                id: vectorTransitMarkerID($0.id),
                coordinate: $0.coordinate
            )
        }
        markers += inputs.boarding.map {
            MapHomeVectorMarker(
                id: vectorBoardingCandidateMarkerID($0.id),
                coordinate: CLLocationCoordinate2D(
                    latitude: $0.point.latitude,
                    longitude: $0.point.longitude
                )
            )
        }
        markers += inputs.stickers.compactMap { sticker in
            guard let point = sticker.point else { return nil }
            return MapHomeVectorMarker(
                id: vectorMapStickerMarkerID(sticker.id),
                coordinate: CLLocationCoordinate2D(
                    latitude: point.latitude,
                    longitude: point.longitude
                )
            )
        }
        markers += inputs.photos.map {
            MapHomeVectorMarker(id: vectorPhotoMarkerID($0.id), coordinate: $0.coordinate)
        }
        markers += inputs.memos.compactMap { memo in
            guard let point = memo.mapPoint else { return nil }
            return MapHomeVectorMarker(
                id: vectorMapMemoMarkerID(memo.id),
                coordinate: CLLocationCoordinate2D(
                    latitude: point.latitude,
                    longitude: point.longitude
                )
            )
        }
        if let displayedLocationCoordinate {
            markers.append(
                MapHomeVectorMarker(
                    id: vectorDisplayedMarkerID,
                    coordinate: displayedLocationCoordinate
                )
            )
        }
        if let selectedSearchPin {
            markers.append(
                MapHomeVectorMarker(
                    id: vectorSearchMarkerID,
                    coordinate: selectedSearchPin.coordinate
                )
            )
        }
        for waypoint in waypoints {
            markers.append(
                MapHomeVectorMarker(
                    id: vectorPawprintMarkerID(waypoint.index),
                    coordinate: waypoint.coordinate
                )
            )
        }
        return markers
    }

    private var vectorPlayerHeading: CLLocationDirection {
        appleMapPlayback?.headingDegrees ?? 0
    }

    private func predictedRoute(source: String, travelID: UUID? = nil, mode: TravelMode,
                                span: TimeSpan, coordinates: [CLLocationCoordinate2D]) -> MapPredictedRoute {
        MapPredictedRoute(source: source, travelID: travelID, mode: mode, span: span,
            coordinates: coordinates.map { GeoPoint(latitude: $0.latitude, longitude: $0.longitude,
                altitude: 0, horizontalAccuracy: -1, verticalAccuracy: -1) })
    }

    private func predictedRoute(for overlay: MapHomeExpectedRouteOverlay) -> MapPredictedRoute {
        predictedRoute(source: overlay.mode == .subway || overlay.mode == .train ? "rail" : "forecast",
            travelID: overlay.segmentID, mode: overlay.mode,
            span: TimeSpan(start: overlay.departureDate, end: overlay.arrivalDate), coordinates: overlay.coordinates)
    }

    private func predictedRoute(for overlay: MapHomeWBSGeneratedRouteOverlay) -> MapPredictedRoute {
        let mode = overlay.mode ?? .walking
        let matching = currentDayDataSnapshot?.travel.filter {
            abs($0.span.start.timeIntervalSince(overlay.departureDate)) <= 1
                && abs($0.span.end.timeIntervalSince(overlay.arrivalDate)) <= 1
        } ?? []
        return predictedRoute(source: mode == .subway || mode == .train ? "rail" : "forecast",
            travelID: matching.count == 1 ? matching[0].id : nil,
            mode: mode, span: TimeSpan(start: overlay.departureDate, end: overlay.arrivalDate),
            coordinates: overlay.coordinates)
    }

    private func predictedRoute(for overlay: MapHomeSubwayRouteOverlay) -> MapPredictedRoute? {
        guard let travel = currentDayDataSnapshot?.travel.first(where: { $0.id == (overlay.travelID ?? overlay.id) }) else { return nil }
        let points = travel.subwayRoute?.coordinates.map {
            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
        } ?? overlay.coordinates
        return predictedRoute(source: "rail", travelID: travel.id, mode: travel.mode,
            span: travel.span, coordinates: points.count >= 2 ? points : overlay.coordinates)
    }

    private func hasRouteDecision(_ route: MapPredictedRoute) -> Bool {
        model.snapshot.settings.predictedRouteDecisions.contains { $0.matches(route) }
    }

    private var predictedMapRoutes: [MapPredictedRoute] {
        let probe = MapHomePlaybackProbe.begin("predictedMapRoutes"); defer { MapHomePlaybackProbe.end(probe) }
        let cutoff = routeOverlayCutoff
        // 지난 날짜에는 예상 경로(일정·학습으로 만든 회색 경로)와 공백 추정을 만들지 않는다. 실제 이동에서 풀린 지하철 구간만 남긴다.
        // 예전에는 지하철 예상 경로가 "rail"로 남아, 차로 이동한 날에도 지하철 회색 발자국이 계속 나왔다(ARC1030A02).
        let isPastDay = !Calendar.autoupdatingCurrent.isDateInToday(model.selectedDate)
        var routes: [MapPredictedRoute] = []
        if !isPastDay {
            routes += expectedRouteOverlays.filter { $0.departureDate < cutoff }.map { predictedRoute(for: $0) }
            routes += wbsGeneratedRouteOverlays.filter { $0.departureDate < cutoff }.map { predictedRoute(for: $0) }
        }
        routes += subwayRouteOverlays.compactMap { predictedRoute(for: $0) }
        // 하루 전체에서 한 번 구한 틈을 컷오프로 거른다. 틈은 앞뒤 두 위치로 정해지므로 컷오프로 먼저 자르는 것과 같다(ARC1030A01).
        let allGaps = predictedGapsMemo.value(for: MapHomeReadingsSignature(
            day: Calendar.autoupdatingCurrent.startOfDay(for: model.selectedDate), sourceRevision: nil,
            storedCount: normalizedRouteReadings.count, storedLastID: normalizedRouteReadings.last?.id,
            liveCount: 0, liveLastID: nil, latestID: nil
        )) {
            MapHomeGPSGapPredictionPolicy.predictedGaps(from: normalizedRouteReadings)
        }
        routes += (isPastDay ? [] : allGaps).filter { $0.end.timestamp <= cutoff }.compactMap { gap in
            guard let first = gap.start.point, let last = gap.end.point else { return nil }
            return MapPredictedRoute(source: "gps-gap", travelID: nil, mode: .walking,
                span: TimeSpan(start: gap.start.timestamp, end: gap.end.timestamp),
                coordinates: [first] + gap.coordinates.map {
                    GeoPoint(latitude: $0.latitude, longitude: $0.longitude, altitude: 0,
                        horizontalAccuracy: -1, verticalAccuracy: -1)
                } + [last])
        }
        var seen = Set<String>()
        return routes.filter { $0.isValid && !hasRouteDecision($0) && seen.insert($0.id).inserted }
    }

    private var confirmedPredictedRoutes: [MapPredictedRoute] {
        let calendar = Calendar.autoupdatingCurrent
        let start = calendar.startOfDay(for: model.selectedDate)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        return model.snapshot.settings.predictedRouteDecisions.filter {
            !$0.isDeleted && $0.route.isValid
                && $0.route.span.start < end && $0.route.span.end > start
        }.map(\.route)
    }

    private func coordinates(for route: MapPredictedRoute, through cutoff: Date? = nil) -> [CLLocationCoordinate2D] {
        let points = route.coordinates.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        guard let cutoff else { return points }
        let fraction = min(1, max(0, cutoff.timeIntervalSince(route.span.start) / route.span.duration))
        guard fraction > 0 else { return [] }
        return MapHomeExpectedRouteOverlay.prefixByDistanceResult(points, fraction: fraction,
            segmentLengths: MapHomeExpectedRoutePlaybackMath.segmentLengths(for: points)).coordinates
    }

    private var vectorUserSelectedRoutes: [MapHomeVectorRoute] {
        var routes = confirmedPredictedRoutes.map { route in
            let points = coordinates(for: route, through: routeOverlayCutoff)
            return MapHomeVectorRoute(id: "confirmed-predicted-\(route.id)", coordinates: points,
                geometrySignature: MapHomeRouteGeometrySignature.value(for: points),
                colorHex: MapHomeWBSTripStyle.actualRouteHex, opacity: 0.95)
        }
        if let selectedPredictedRoute {
            let points = coordinates(for: selectedPredictedRoute)
            routes.append(MapHomeVectorRoute(id: "selected-\(selectedPredictedRoute.id)", coordinates: points,
                geometrySignature: MapHomeRouteGeometrySignature.value(for: points),
                colorHex: "#FF9800", opacity: 1))
        }
        return routes
    }

    /// 화랑이를 누르면 하루 요약 카드를 연다. 발자국·집 아이콘보다 먼저 판정한다(대표 지시, ARC1030A07).
    /// 지도 탭 한 경로(UIKit 탭이 부른다). 좌표는 지도 로컬 하나만 쓴다. 예전에는 SwiftUI 탭(뷰포트 좌표)과
    /// UIKit 탭(지도 로컬 좌표)이 같은 손짓을 두 번 판정했고, 카운터 창 판정에 서로 다른 좌표가 섞였다(PRF1101A01).
    private func handleMapTap(atLocal local: CGPoint, waypoints: [PawprintWaypoint], positions: [String: CGPoint]?) {
        defer { if isSearchDismissable { dismissMapSearchOverlay() } }
        if isCounterWindowTapped(at: local) {
            openCounterDetail(at: local)
            return
        }
        if isStickmanTapped(at: local) {
            presentDaySummary(fromCat: true)
            return
        }
        if handleMapMarkerTap(at: local) { return }
        if let waypoint = pawprintTarget(at: local, waypoints: waypoints, positions: positions) {
            selectPawprint(waypoint)
            return
        }
        if isHomeSummaryTapped(at: local) { isDaySummaryPresented = true }
    }

    private func viewportPoint(fromMapLocal point: CGPoint) -> CGPoint {
        CGPoint(x: point.x + mapFrameInViewport.minX, y: point.y + mapFrameInViewport.minY)
    }

    /// 지도 위 핀(메모·사진·탑승 후보·대중교통·장소)은 터치를 받지 않고 여기서 위치로 판정한다.
    /// 핀이 두 손가락 핀치를 가로채지 않게 하려는 것이다(대표 지시). 위에 그려진 것부터 본다.
    private func handleMapMarkerTap(at tapPoint: CGPoint) -> Bool {
        guard let viewport = vectorMapViewportStore.viewport else { return false }
        func hit(_ id: String, width: CGFloat = 56, height: CGFloat = 64) -> Bool {
            guard let point = vectorPoint(in: viewport, for: id) else { return false }
            return CGRect(x: point.x - width / 2, y: point.y - height, width: width, height: height + 10).contains(tapPoint)
        }
        if recordingShows(\.mapMemos), let memo = mapMemosOnMap.last(where: { hit(vectorMapMemoMarkerID($0.id)) }) {
            selectedMapStickerEditor = .memo(memo.id)
            return true
        }
        if !isDayPlaybackRunning, !isScreenRecording,
           let cluster = photoClusters.last(where: { cluster in
               photoPinPoint(cluster, in: viewport, places: placeAnnotations).map {
                   CGRect(x: $0.x - 28, y: $0.y - 64, width: 56, height: 74).contains(tapPoint)
               } ?? false
           }) {
            photoAlbumSelection = MapHomePhotoAlbumSelection(id: cluster.id, moments: cluster.moments)
            return true
        }
        if let candidate = transitBoardingCandidates.last(where: { hit(vectorBoardingCandidateMarkerID($0.id)) }) {
            selectedTransitBoardingCandidate = candidate
            return true
        }
        if let place = transitAnnotations.last(where: { hit(vectorTransitMarkerID($0.id)) }) {
            selectedUserLocation = .transit(place.id)
            return true
        }
        // 집 핀은 아래 `isHomeSummaryTapped`가 맡는다.
        if let place = placeAnnotations.last(where: {
            $0.destination != .home && hit(vectorPlaceMarkerID($0.id), width: 80, height: 90)
        }) {
            if place.destination == .user {
                selectedUserLocation = .frequentPlace(place.id)
            } else {
                selectedMarkerPlaceID = place.id
                selectedMarkerInfo = .landmark(place.destination)
            }
            return true
        }
        return false
    }

    /// 화랑이 위 카운터 위젯을 눌렀는지. 위젯을 눌러도 지도 이동이 막히지 않게 지도 탭에서 영역으로 판정한다.
    /// 카운터 창 자리는 지도 오버레이(=지도 로컬) 좌표로 기록된다.
    private func isCounterWindowTapped(at tapPoint: CGPoint) -> Bool {
        let frame = counterWindowFrame.frame
        return frame.width > 0 && frame.height > 0 && frame.insetBy(dx: -8, dy: -8).contains(tapPoint)
    }

    /// 누른 줄의 카운터 상세 화면을 연다. 줄은 위에서 아래로 같은 높이로 쌓여 있어 높이 비율로 고른다.
    /// 줄 목록을 아직 모르면(창이 막 생긴 때) 예전처럼 카운터 메뉴를 연다.
    private func openCounterDetail(at tapPoint: CGPoint) {
        let rows: CGRect
        switch MapHomeCounterFold.tap(atY: tapPoint.y, frame: counterWindowFrame.frame, isCollapsed: isCounterCollapsed) {
        case .expand, .collapse:
            withAnimation(.snappy(duration: 0.22)) { isCounterCollapsed.toggle() }
            return
        case .rows(let frame): rows = frame
        }
        let targets = counterRowTargets
        guard let index = MapHomeCounterDetailBuilder.rowIndex(
            tapY: tapPoint.y, frame: rows, count: targets.count
        ) else {
            openCounterMenu()
            return
        }
        counterDetail = targets[index]
    }

    /// 상세 화면 내용. 연 순간의 값으로 만든다.
    private func counterDetailContent(for target: MapHomeCounterDetailTarget) -> MapHomeCounterDetailContent {
        let calendar = Calendar.autoupdatingCurrent
        let dayStart = calendar.startOfDay(for: model.selectedDate)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(24 * 60 * 60)
        let now = Date()
        let badges = mapCounterBadges(asOf: now)
        switch target {
        case .salary:
            let live = salaryLive
            let workSeconds: TimeInterval
            if let minute = counterCutoffMinute {
                workSeconds = MapHomeSalaryPolicy.workSeconds(in: salaryWorkSpans[dayStart] ?? [], until: dayStart + minute * 60)
            } else if calendar.isDateInToday(model.selectedDate), let live {
                workSeconds = MapHomeSalaryPolicy.liveWorkSeconds(
                    base: live.todayWorkSeconds, baseDate: live.measuredAt, isWorking: live.isWorking, now: now, tick: 1
                )
            } else {
                workSeconds = MapHomeSalaryPolicy.workSeconds(in: salaryWorkSpans[dayStart] ?? [], until: .distantFuture)
            }
            let rate = live?.hourlyRate ?? 0
            return MapHomeCounterDetailBuilder.salary(
                spans: salaryWorkSpans[dayStart] ?? [],
                earned: MapHomeSalaryPolicy.wonText(
                    MapHomeSalaryPolicy.earnings(workSeconds: workSeconds, hourlyRate: rate), language: language
                ),
                hourlyRateText: MapHomeSalaryPolicy.wonText(rate, language: language),
                language: language
            )
        case .allowance:
            return MapHomeAllowancePolicy.detail(day: dayStart, playbackMinute: counterCutoffMinute, now: now, language: language)
        case .kind(let kind):
            let total = badges.first(where: { $0.kind == kind })?.text ?? "–"
            switch kind {
            case .steps:
                return MapHomeCounterDetailBuilder.steps(
                    readings: currentDayReadings, total: total, dayStart: dayStart, language: language
                )
            case .distance:
                return MapHomeCounterDetailBuilder.distance(
                    segments: MapHomeCounterTimelinePolicy.visibleSegments(
                        displayDayDataSnapshot?.travel ?? [], cutoff: counterCutoffDate, day: selectedDaySpan
                    ), total: total, language: language
                )
            case .work, .study, .hobby, .exercise:
                let seconds = kind.categoryID.flatMap { daySummaryCategorySeconds(asOf: counterCutoffDate, now: now)[$0] } ?? 0
                return MapHomeCounterDetailBuilder.time(
                    kind: kind,
                    actuals: displayDayDataSnapshot?.actuals ?? [],
                    totalSeconds: seconds,
                    total: total,
                    dayStart: dayStart,
                    dayEnd: dayEnd,
                    now: now,
                    language: language
                )
            }
        }
    }

    /// 왼쪽 메뉴를 열고 표시 > 카운터 항목을 펼친다(위젯을 누르면 카운터 메뉴로 볼 수 있는 내용만 보여 준다).
    private func openCounterMenu() {
        openMenu()
        isDisplayMenuExpanded = true
        isCounterMenuExpanded = true
    }

    /// 화랑이가 화면에 그려지는 점. 재생 중에는 구동기가 프레임마다 정한 점이 가장 정확하다.
    private func isStickmanTapped(at tapPoint: CGPoint) -> Bool {
        guard let stickmanPoint = displayedCatViewportPoint else { return false }
        return MapHomeCatTapRouting.shouldPresentCatDetails(
            tapPoint: tapPoint,
            locationPoint: stickmanPoint,
            isAtHome: isDisplayedCatAtHome
        )
    }

    /// 집 아이콘·레벨 라벨 탭. 핀 안쪽 제스처에 기대지 않고 지도 단위 탭에서 집 핀 좌표로 판정한다.
    private func isHomeSummaryTapped(at tapPoint: CGPoint) -> Bool {
        guard let home = model.settings.frequentPlaces.first(where: { $0.kind == .home }),
              let viewport = vectorMapViewportStore.viewport,
              let pinPoint = vectorPoint(in: viewport, for: vectorPlaceMarkerID(home.id)) else { return false }
        // 집 아이콘(핀 위쪽)과 레벨 라벨 영역을 넓게 잡는다. 화랑이가 집에 있어도 같은 영역이다.
        let iconRect = CGRect(x: pinPoint.x - 56, y: pinPoint.y - 110, width: 112, height: 150)
        return iconRect.contains(tapPoint)
    }

    private func pawprintTarget(
        at point: CGPoint,
        waypoints: [PawprintWaypoint],
        positions: [String: CGPoint]? = nil
    ) -> PawprintWaypoint? {
        guard let positions = positions ?? vectorMapViewportStore.viewport?.markerPoints else { return nil }
        let targets = waypoints.compactMap { waypoint -> MapHomePawprintTapTarget? in
            guard let position = positions[vectorPawprintMarkerID(waypoint.index)]
            else { return nil }
            return MapHomePawprintTapTarget(
                id: waypoint.index, point: position,
                timestamp: waypoint.timestamp, isPredicted: waypoint.isPredicted,
                routeID: waypoint.predictedRoute?.id,
                routeSpan: waypoint.predictedRoute?.span
            )
        }
        guard let id = MapHomePawprintInteractionPolicy.nearestTarget(
            to: point, targets: targets, selectedDate: model.selectedDate
        ) else { return nil }
        return waypoints.first { $0.index == id }
    }

    private func selectPawprint(_ waypoint: PawprintWaypoint) {
        if let route = waypoint.predictedRoute {
            stopDayPlayback(resetProgress: false)
            recordUserMapAdjustment()
            currentLocationRequestTask?.cancel()
            currentLocationRequestTask = nil
            setUserTrackingMode(.idle)
            selectedPredictedRoute = route
            dismissMapSearchOverlay()
            return
        }
        guard let selection = MapHomePawprintInteractionPolicy.selection(
            timestamp: waypoint.timestamp, isPredicted: waypoint.isPredicted,
            selectedDate: model.selectedDate
        ) else { return }
        stopDayPlayback(resetProgress: true)
        isTimelineInteractionActive = false
        recordUserMapAdjustment()
        currentLocationRequestTask?.cancel()
        currentLocationRequestTask = nil
        setUserTrackingMode(.idle)
        isTimelineSelectionPinned = true
        selectedTimelineMinute = selection.minute
        selectedPawprintTimestamp = selection.timestamp
        highlightedPawprintTimestamp = waypoint.timestamp
        selectedPawprintCoordinate = waypoint.coordinate
        _ = refreshRouteProjection()
        recordCurrentPlaybackAlignment()
        focusMap(on: wbsGeoPoint(waypoint.coordinate), using: nil, followsTracking: true)
        dismissMapSearchOverlay()
    }

    private func vectorMapAnnotationOverlay(
        style: MapHomeVectorStyle,
        viewport: MapHomeVectorViewport?,
        stickmanPoint: CGPoint?,
        waypoints allWaypoints: [PawprintWaypoint],
        inputs: MapHomeOverlayInputs,
        playback: MapHomeApplePlayback?,
        displayedSpeed: Double?
    ) -> some View {
        _ = MapHomePlaybackFrameStats.noteOverlayEvaluation()
        // 구동기 재생 중에는 화랑이가 지나간 시각까지의 발자국만 화면 틱마다 보여, 발자국이 화랑이 발밑에 바로 찍힌다(ARC1030A02).
        let waypoints = playbackVisibleWaypoints(allWaypoints)
        let places = inputs.places
        return ZStack {
            if fogStrength != .off {
                MapHomeFogLayer(
                    opacity: fogStrength.opacity,
                    reveals: fogReveals(viewport: viewport, waypoints: waypoints, places: places, stickmanPoint: stickmanPoint)
                )
            }
            homeLandOverlay(viewport: viewport)
            placeZoneOverlay(viewport: viewport)
            // `waypoints`는 이미 그리는 순서로 정렬돼 있다(`vectorMap(style:)`).
            ForEach(recordingShows(\.footprints) && !Self.benchHidden("paws") ? waypoints : []) { waypoint in
                if let point = vectorPoint(
                    in: viewport,
                    for: vectorPawprintMarkerID(waypoint.index)
                ) {
                    MapHomeProjectedAnnotation(point: point, anchor: .center) {
                        if let timestamp = waypoint.timestamp, !waypoint.isPredicted {
                            pawprintImage(waypoint)
                                .accessibilityLabel(
                                    Text(language.text("기록 발자국 ", "Recorded paw "))
                                        + Text(timestamp, style: .time)
                                )
                                .accessibilityAddTraits(.isButton)
                                .accessibilityAction { selectPawprint(waypoint) }
                        } else if waypoint.predictedRoute != nil {
                            pawprintImage(waypoint)
                                .accessibilityLabel(language.text("예상 경로 선택", "Select predicted route"))
                                .accessibilityAddTraits(.isButton)
                                .accessibilityAction { selectPawprint(waypoint) }
                        } else {
                            pawprintImage(waypoint).accessibilityHidden(true)
                        }
                    }
                }
            }
            ForEach(inputs.temporaryLocations) { location in
                if let point = vectorPoint(
                    in: viewport,
                    for: vectorTemporaryMarkerID(location.id)
                ) {
                    MapHomeProjectedAnnotation(point: point, anchor: .bottom) {
                        VStack(spacing: 2) {
                            Image(systemName: "tram.fill")
                                .font(.system(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .semibold))
                                .foregroundStyle(Color.tpReferenceBlue.opacity(0.72))
                            Text(language.text("임시 위치", "Temporary"))
                                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(9)), weight: .semibold))
                                .foregroundStyle(Color.tpInk.opacity(0.72))
                        }
                        .padding(5)
                        .background(Color.tpSurface.opacity(0.66), in: Capsule())
                        .overlay {
                            Capsule().stroke(
                                Color.tpReferenceBlue.opacity(0.45),
                                style: StrokeStyle(lineWidth: 1, dash: [3, 2])
                            )
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(
                            language.text(
                                "\(location.stationName) 지하철 임시 위치",
                                "\(location.stationName) temporary subway location"
                            )
                        )
                        .allowsHitTesting(false)
                    }
                }
            }

            ForEach(places) { place in
                if let point = vectorPoint(
                    in: viewport,
                    for: vectorPlaceMarkerID(place.id)
                ) {
                    MapHomeProjectedAnnotation(
                        point: point,
                        anchor: MapHomePlaceAnnotationLayout.vectorAnchor
                    ) {
                        if place.destination == .user {
                            MapHomePlacePin(
                                name: place.name,
                                floor: place.floor,
                                destination: place.destination,
                                growthLevel: place.growthLevel,
                                isLeapDay: place.isLeapDay,
                                growthStatus: place.growthStatus,
                                isGrowthQualifiedToday: place.isGrowthQualifiedToday,
                                growthStreak: place.growthStreak,
                                pendingWeeklyRewards: place.pendingWeeklyRewards,
                                showsCatAtHome: place.isCatAtHome,
                                catAction: place.catAction,
                                equippedAccessoryID: place.equippedAccessoryID
                            )
                            .fixedSize()
                            // 탭은 지도 탭에서 위치로 판정한다(두 손가락 핀치가 핀에 막히지 않게).
                            .allowsHitTesting(false)
                            .accessibilityAddTraits(.isButton)
                            .accessibilityLabel(
                                language.text(
                                    place.name + " 사용자 위치 메뉴",
                                    place.name + " user location menu"
                                )
                            )
                        } else {
                            if place.destination == .home {
                                MapHomePlacePin(
                                    name: place.name,
                                    floor: place.floor,
                                    destination: place.destination,
                                    growthLevel: place.growthLevel,
                                    isLeapDay: place.isLeapDay,
                                    growthStatus: place.growthStatus,
                                    isGrowthQualifiedToday: place.isGrowthQualifiedToday,
                                    growthStreak: place.growthStreak,
                                    pendingWeeklyRewards: place.pendingWeeklyRewards,
                                    showsCatAtHome: place.isCatAtHome,
                                    catAction: place.catAction,
                                    equippedAccessoryID: place.equippedAccessoryID,
                                    weatherBadge: place.weatherBadge,
                                    homeSky: place.homeSky,
                                    onOpenDaySummary: { isDaySummaryPresented = true }
                                )
                                .fixedSize()
                                .allowsHitTesting(false)
                                .accessibilityAddTraits(.isButton)
                            } else {
                                MapHomePlacePin(
                                    name: place.name,
                                    floor: place.floor,
                                    destination: place.destination,
                                    growthLevel: place.growthLevel,
                                    isLeapDay: place.isLeapDay,
                                    growthStatus: place.growthStatus,
                                    isGrowthQualifiedToday: place.isGrowthQualifiedToday,
                                    growthStreak: place.growthStreak,
                                    pendingWeeklyRewards: place.pendingWeeklyRewards,
                                    showsCatAtHome: place.isCatAtHome,
                                    catAction: place.catAction,
                                    equippedAccessoryID: place.equippedAccessoryID
                                )
                                .fixedSize()
                                .allowsHitTesting(false)
                                .accessibilityAddTraits(.isButton)
                                .accessibilityLabel(
                                    language.text(
                                        "\(place.name), 레벨 \(place.floor ?? 1)",
                                        "\(place.name), level \(place.floor ?? 1)"
                                    )
                                )
                            }
                        }
                    }
                    .zIndex(MapHomePlaceDisplayPolicy.vectorZIndex(for: place.destination))
                }
            }

            ForEach(inputs.transit) { place in
                if let point = vectorPoint(
                    in: viewport,
                    for: vectorTransitMarkerID(place.id)
                ) {
                    MapHomeProjectedAnnotation(point: point, anchor: .bottom) {
                    Button {
                        selectedUserLocation = .transit(place.id)
                        } label: {
                            MapHomeTransitPlacePin(name: place.name, kind: place.kind)
                                .fixedSize()
                        }
                        .buttonStyle(.plain)
                        .allowsHitTesting(false)
                        .accessibilityLabel(
                            language.text(
                                place.name + " 사용자 위치 메뉴",
                                place.name + " user location menu"
                            )
                        )
                    }
                }
            }

            ForEach(inputs.boarding) { candidate in
                if let point = vectorPoint(
                    in: viewport,
                    for: vectorBoardingCandidateMarkerID(candidate.id)
                ) {
                    MapHomeProjectedAnnotation(point: point, anchor: .bottom) {
                        Button {
                            selectedTransitBoardingCandidate = candidate
                        } label: {
                            MapHomeTransitBoardingCandidatePin(
                                name: TransitPlaceName.display(candidate.name, kind: candidate.kind, point: candidate.point, language: language),
                                kind: candidate.kind
                            )
                            .fixedSize()
                        }
                        .buttonStyle(.plain)
                        .allowsHitTesting(false)
                        .accessibilityLabel(
                            language.text(
                                "\(candidate.name) \(candidate.kind.title) 탑승 확인",
                                "Confirm boarding at \(candidate.name) \(candidate.kind.englishTitle)"
                            )
                        )
                    }
                }
            }

            ForEach(inputs.stickers) { sticker in
                if let point = vectorPoint(
                    in: viewport,
                    for: vectorMapStickerMarkerID(sticker.id)
                ) {
                    MapHomeProjectedAnnotation(point: point, anchor: .bottom) {
                        Button {
                            selectedMapStickerEditor = .sticker(sticker.id)
                        } label: {
                            MapHomeMapStickerMarker(sticker: sticker)
                        }
                        .buttonStyle(.plain)
                        .allowsHitTesting(isStickerMode)
                        .accessibilityLabel(
                            language.text(
                                "\(sticker.title) 메모 스티커",
                                "\(sticker.title) memo sticker"
                            )
                        )
                    }
                }
            }

            ForEach(inputs.photos) { cluster in
                if let info = photoPinInfo(for: cluster),
                   let point = photoPinPoint(cluster, in: viewport, places: inputs.places) {
                    MapHomeProjectedAnnotation(point: point, anchor: .bottom) {
                        Button {
                            photoAlbumSelection = MapHomePhotoAlbumSelection(
                                id: cluster.id,
                                moments: cluster.moments
                            )
                        } label: {
                            MapHomePhotoPin(
                                coverID: info.coverID,
                                count: info.count,
                                isHighlighted: info.highlighted
                            )
                            .transition(.scale.combined(with: .opacity))
                        }
                        .buttonStyle(.plain)
                        .allowsHitTesting(false)
                    }
                    .animation(.easeOut(duration: 0.25), value: info.coverID)
                }
            }

            ForEach(recordingShows(\.mapMemos) ? inputs.memos : []) { memo in
                if let projected = vectorPoint(
                    in: viewport,
                    for: vectorMapMemoMarkerID(memo.id)
                ) {
                    MapHomeProjectedAnnotation(point: projected, anchor: .bottom) {
                        Button {
                            selectedMapStickerEditor = .memo(memo.id)
                        } label: {
                            MapHomeMapMemoMarker(memo: memo)
                        }
                        .buttonStyle(.plain)
                        .allowsHitTesting(false)
                        .accessibilityLabel(
                            language.text(
                                "\(memo.text) 지도 메모, \(memo.occurredAt.formatted(date: .omitted, time: .shortened))",
                                "\(memo.text) map memo, \(memo.occurredAt.formatted(date: .omitted, time: .shortened))"
                            )
                        )
                    }
                }
            }

            if selectedTimelineMinute != nil,
               !isDisplayedCatAtHome,
               let point = (playbackDriver != nil ? vectorMapViewportStore.livePoint : nil)
                   ?? vectorPoint(in: viewport, for: vectorDisplayedMarkerID) {
                // 구동기 재생 중에는 화살표를 화랑이와 같은 점에 둔다(대표 지시, ARC1030A02).
                MapHomeVectorPlayerMarker(
                    heading: playback?.headingDegrees ?? 0,
                    backgroundHex: style.backgroundHex
                )
                    .position(x: point.x, y: point.y + 11)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }

            if let playback,
               recordingShows(\.cat),
               stickmanPoint != nil || vectorMapViewportStore.livePoint != nil {
                // 재생 중에는 UIKit 뷰가 `liveChannel` 점으로 위치만 옮긴다. SwiftUI는 매 프레임 다시 그리지 않는다(PRF1101A01).
                let point = vectorMapViewportStore.livePoint ?? stickmanPoint ?? .zero
                let offset = MapHomeStickmanAnnotationLayout.centerOffset
                MapHomeLivePointFollower(
                    channel: playbackDriver == nil ? nil : vectorMapViewportStore.liveChannel,
                    fallback: CGPoint(x: point.x + offset.x, y: point.y + offset.y),
                    offset: CGSize(width: offset.x, height: offset.y)
                ) {
                MapHomeStickmanMarker(
                    action: playback.action,
                    animationPhase: playbackDriver == nil ? playback.stickmanAnimationPhase : nil,
                    routePhase: playback.phase == .forecast
                        ? .forecast
                        : .actual,
                    speedMetersPerSecond: displayedSpeed,
                    equippedAccessoryID: homeGrowthHistory.season.equippedAccessory,
                    facesLeft: MapHomeStickmanFacing.facesLeft(
                        headingDegrees: playback.headingDegrees,
                        cameraHeading: viewport?.heading ?? 0
                    )
                    )
                }
                    .zIndex(MapHomeLayerPriority.stickman)
                    // 화랑이 위에서도 지도 팬·핀치줌이 최우선이 되도록 마커는
                    // 히트테스트에서 제외한다(다른 마커와 동일). UIKit 지도 위의
                    // SwiftUI simultaneousGesture는 드래그를 지도로 흘려보내지
                    // 못해 고양이 주변 터치를 삼켰다. 상세는 중앙 상단 탐험 HUD로
                    // 연다.
                    .allowsHitTesting(false)
                    .accessibilityElement(children: .ignore)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel(
                        "\(playback.accessibilityLabel), \(language.text("설명 보기","Show info"))"
                    )
            }

            // 카운터 창은 녹화에서 끄지 않는 한 늘 보인다: 화랑이가 밖에 있으면 그 위, 집에 있으면 집 핀 안의 화랑이 위.
            // 연봉과 나머지 카운터는 한 상자에 담는다(표시 > 카운터에서 켠 것만).
            if recordingShows(\.counterWidget),
               let anchor = salaryAnchor(viewport: viewport, stickmanPoint: playback == nil ? nil : stickmanPoint) {
                counterWindow(at: anchor, tracksPlaybackPoint: playback != nil)
            }

            if let selectedSearchPin,
               let point = vectorPoint(in: viewport, for: vectorSearchMarkerID) {
                MapHomeProjectedAnnotation(point: point, anchor: .bottom) {
                    Button {
                        isSearchPinMenuPresented = true
                    } label: {
                        Image(systemName: "mappin.circle.fill")
                            .font(.system(size: TaptionType.scaled(TaptionType.snapped(36)), weight: .bold))
                            .foregroundStyle(Color.tpPastelRose)
                            .background(Circle().fill(.white))
                            .frame(width: 48, height: 48)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        language.text(
                            "\(selectedSearchPin.title) 위치 추가",
                            "Add \(selectedSearchPin.title) location"
                        )
                    )
                }
            }
        }
        .clipped()
    }

    /// 안개 탐험에서 걷어낼 지점. 지도 좌표를 화면 좌표로 옮겨 `MapHomeFogLayer`에 넘긴다.
    private func fogReveals(
        viewport: MapHomeVectorViewport?,
        waypoints: [PawprintWaypoint],
        places: [MapHomePlaceAnnotation],
        stickmanPoint: CGPoint? = nil
    ) -> [(point: CGPoint, radius: CGFloat)] {
        guard let viewport else { return [] }
        let radius = MapHomeFogStrength.revealRadius
        var reveals = waypoints.compactMap {
            viewport.markerPoints[vectorPawprintMarkerID($0.index)]
        }.map { (point: $0, radius: radius) }
        reveals += places.compactMap {
            viewport.markerPoints[vectorPlaceMarkerID($0.id)]
        }.map { (point: $0, radius: radius) }
        if let point = MapHomeFogRevealPolicy.currentLocationPoint(
            stickmanPoint: stickmanPoint,
            viewportPoint: viewport.markerPoints[vectorDisplayedMarkerID]
        ) {
            reveals.append((point: point, radius: MapHomeFogStrength.currentLocationRadius))
        }
        return reveals
    }

        private var vectorDisplayedMarkerID: String { "displayed-location" }
    private var vectorSearchMarkerID: String { "search-location" }

    private func vectorTemporaryMarkerID(_ id: UUID) -> String {
        "temporary-\(id.uuidString)"
    }

    private struct PawprintWaypoint: Identifiable {
        let index: Int
        let coordinate: CLLocationCoordinate2D
        let angle: Double
        let isPredicted: Bool
        let timestamp: Date?
        var predictedRoute: MapPredictedRoute? = nil
        var speedMetersPerSecond: Double? = nil
        var id: Int { index }
    }

    private func pawprintImage(_ waypoint: PawprintWaypoint) -> some View {
        // 선택한 발자국은 흰색 배경(100%)과 강조 테두리로 표시한다.
        let isSelected = !waypoint.isPredicted && waypoint.timestamp != nil
            && waypoint.timestamp == highlightedPawprintTimestamp
        return Image(systemName: "pawprint.fill")
            .font(.system(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .bold))
            .foregroundStyle(waypoint.predictedRoute != nil && waypoint.predictedRoute?.id == selectedPredictedRoute?.id && waypoint.isPredicted
                ? Color.orange : waypoint.isPredicted ? MapHomePawprintSpeedColor.unconfirmedColor(forMetersPerSecond: waypoint.speedMetersPerSecond)
                : MapHomePawprintSpeedColor.color(forMetersPerSecond: waypoint.speedMetersPerSecond))
            .rotationEffect(.degrees(waypoint.angle))
            .padding(isSelected ? 5 : 0)
            .background(Circle().fill(isSelected ? Color.white : Color.clear))
            .overlay(Circle().stroke(isSelected ? Color.tpAccent : Color.clear, lineWidth: 2))
            .allowsHitTesting(false)
    }

    /// 실제 경로의 좌표와 시각을 함께 샘플링하며 예상 발자국에는 시각을 부여하지 않는다.
    /// 구동기 재생 중에는 화랑이가 지나간 시각까지의 발자국만 보여, 발자국이 화랑이가 지나가면서 깔린다(대표 지시, ARC1030A05).
    /// 재생을 누르자마자 하루치 발자국이 한꺼번에 깔리던 것을 막는다. 벡터 지도는 화면 틱마다, Apple 지도는 분 알림마다 부른다.
    private func playbackVisibleWaypoints(_ all: [PawprintWaypoint]) -> [PawprintWaypoint] {
        guard let driver = playbackDriver else { return all }
        let now = driver.inputs.dayStart.addingTimeInterval(driver.minute * 60)
        return all.filter { $0.timestamp.map { $0 <= now } ?? true }
    }

    /// 하루 발자국 장부(기록이 늘 때만 다시 만든다). 확정된 지하철 구간은 선으로 그려져 발자국을 놓지 않는다.
    private func pawprintLedger() -> [MapHomePawprintLedger.Entry] {
        let readings = currentDayReadings
        let excluded = MapHomePawprintLedger.lineDrawnSpans(in: displayDayDataSnapshot?.travel ?? [])
        let key = MapHomePawprintLedgerKey(
            day: Calendar.autoupdatingCurrent.startOfDay(for: model.selectedDate),
            count: readings.count, firstID: readings.first?.id, lastID: readings.last?.id,
            excluded: excluded.flatMap { [$0.start.timeIntervalSinceReferenceDate, $0.end.timeIntervalSinceReferenceDate] }
        )
        return pawprintLedgerMemo.value(for: key) {
            MapHomePawprintLedger.entries(readings: readings, excluding: excluded)
        }
    }

    /// 한 화면에서 여러 번 읽힌다. 입력(예상·확인 경로, 장부, 컷오프)이 같으면 이전 값을 쓴다(PRF1101A01).
    private var pawprintWaypoints: [PawprintWaypoint] {
        let probe = MapHomePlaybackProbe.begin("pawprintWaypoints"); defer { MapHomePlaybackProbe.end(probe) }
        let predicted = predictedMapRoutes, confirmed = confirmedPredictedRoutes, ledger = pawprintLedger()
        let cutoff = routeOverlayCutoff
        let calendarForDay = Calendar.autoupdatingCurrent
        let dayEnd = calendarForDay.date(byAdding: .day, value: 1, to: calendarForDay.startOfDay(for: model.selectedDate))
            ?? .distantFuture
        let ledgerCutoff = playbackDriver != nil ? dayEnd : cutoff
        let key = MapHomePawprintWaypointsKey(
            day: model.selectedDate, cutoff: cutoff, ledgerCutoff: ledgerCutoff, predicted: predicted, confirmed: confirmed,
            ledgerCount: ledger.count, ledgerFirst: ledger.first?.timestamp, ledgerLast: ledger.last?.timestamp
        )
        return pawprintWaypointsMemo.value(for: key) {
            makePawprintWaypoints(predicted: predicted, confirmed: confirmed, ledger: ledger,
                                  cutoff: cutoff, ledgerCutoff: ledgerCutoff)
        }
    }

    private func makePawprintWaypoints(
        predicted: [MapPredictedRoute], confirmed: [MapPredictedRoute], ledger: [MapHomePawprintLedger.Entry],
        cutoff routeOverlayCutoff: Date, ledgerCutoff: Date
    ) -> [PawprintWaypoint] {
        let hardCap = MapHomePawprintInteractionPolicy.markerLimit
        let predictedSegments = predicted.map { route in
            (route: route, points: MapHomeGPSGapPredictionPolicy.predictedRailCoordinates(
                along: coordinates(for: route, through: routeOverlayCutoff)))
        }
        let confirmedSegments = confirmed.map { route in
            let samples = MapHomeGPSGapPredictionPolicy.predictedRailCoordinates(along: coordinates(for: route))
            let timestamps = samples.indices.map { index in
                route.span.start.addingTimeInterval(route.span.duration
                    * Double(index) / Double(max(1, samples.count - 1)))
            }
            let visible = samples.indices.filter {
                timestamps[$0] <= routeOverlayCutoff && Calendar.autoupdatingCurrent
                    .isDate(timestamps[$0], inSameDayAs: model.selectedDate)
            }
            return (route: route, points: visible.map { samples[$0] }, timestamps: visible.map { timestamps[$0] })
        }
        let inferredCounts = confirmedSegments.map { $0.points.count } + predictedSegments.map { $0.points.count }
        // 기록된 발자국은 장부에서 가져온다. GPS가 기록된 순간의 위치·방향·속도 색이 그대로 유지된다(ARC1030A07).
        var result: [PawprintWaypoint] = []
        for entry in ledger.filter({ $0.timestamp <= ledgerCutoff }).suffix(MapHomePawprintLedger.displayLimit) {
            result.append(PawprintWaypoint(
                index: result.count, coordinate: entry.coordinate, angle: entry.angle, isPredicted: false,
                timestamp: entry.timestamp, speedMetersPerSecond: entry.speed
            ))
        }
        let inferredBudgets = MapHomePawprintInteractionPolicy.distributedCounts(sampleCounts: inferredCounts,
            latestTimestamps: confirmedSegments.map { $0.route.span.end } + predictedSegments.map { $0.route.span.end },
            limit: max(0, hardCap - result.count))
        for (segmentIndex, segment) in confirmedSegments.enumerated() {
            // 확인된 이동은 구간 전체 길이를 시간으로 나눈 평균 속도를 쓴다.
            var segmentSpeed: Double?
            if let firstPoint = segment.points.first, let lastPoint = segment.points.last,
               let firstDate = segment.timestamps.first, let lastDate = segment.timestamps.last {
                let length = zip(segment.points, segment.points.dropFirst()).reduce(0.0) { sum, pair in
                    sum + CLLocation(latitude: pair.0.latitude, longitude: pair.0.longitude)
                        .distance(from: CLLocation(latitude: pair.1.latitude, longitude: pair.1.longitude))
                }
                let seconds = lastDate.timeIntervalSince(firstDate)
                if seconds > 0, firstPoint.latitude.isFinite, lastPoint.latitude.isFinite {
                    segmentSpeed = length / seconds
                }
            }
            for index in MapHomePawprintInteractionPolicy.spreadIndices(
                count: segment.points.count, limit: inferredBudgets[segmentIndex]
            ) {
                let point = segment.points[index]
                result.append(PawprintWaypoint(index: result.count,
                    coordinate: CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude),
                    angle: 0, isPredicted: false, timestamp: segment.timestamps[index],
                    speedMetersPerSecond: segmentSpeed))
            }
        }
        for (segmentIndex, segment) in predictedSegments.enumerated() {
            let points = segment.points.map {
                CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
            }
            let gapSpeed = MapHomeUnconfirmedPaws.speed(points: points, seconds: segment.route.span.duration)
            for index in MapHomePawprintInteractionPolicy.spreadIndices(
                count: points.count, limit: inferredBudgets[confirmedSegments.count + segmentIndex]
            ) {
                let point = points[index]
                let previous = points[max(0, index - 1)]
                let next = points[min(points.count - 1, index + 1)]
                let angle = atan2(next.longitude - previous.longitude, next.latitude - previous.latitude) * 180 / .pi
                result.append(
                    PawprintWaypoint(
                        index: result.count,
                        coordinate: point,
                        angle: angle,
                        isPredicted: true,
                        timestamp: nil,
                        predictedRoute: segment.route,
                        speedMetersPerSecond: gapSpeed
                    )
                )
            }
        }
        let gapReadings = routeReadingsLoadState.isLoaded(for: model.selectedDate) ? historicalPlaybackReadings : []
        for gap in MapHomeUnconfirmedPaws.subwayGapPoints(travel: currentDayDataSnapshot?.travel ?? [], readings: gapReadings, through: routeOverlayCutoff, limit: hardCap - result.count) {
            result.append(PawprintWaypoint(index: result.count, coordinate: gap.coordinate, angle: gap.angle, isPredicted: true, timestamp: nil, speedMetersPerSecond: gap.speed))
        }
        return result
    }

    private func vectorPawprintMarkerID(_ index: Int) -> String {
        "pawprint-\(index)"
    }

    // MARK: 집 주변 땅(지도)

    /// 붙일 땅(타일)이 남아 있고, 카메라가 집 300m 안에서 400m 이하로 가까울 때. 타일을 추가하는 동안만 벡터 스타일이 필요하다.
    private var isNearHomeLand: Bool {
        guard MapHomeLandFeature.isVisible,
              autoLandStyleEnabled,
              let camera = visibleMapCamera, camera.distance <= 400,
              let home = model.settings.frequentPlaces.first(where: { $0.kind == .home })?.point else { return false }
        let season = homeGrowthHistory.season
        let placed = Set((season.landPlotPlacements ?? []).map(\.plotID))
        guard season.landPlots.contains(where: { !placed.contains($0) }) else { return false }
        let center = GeoPoint(
            latitude: camera.centerCoordinate.latitude,
            longitude: camera.centerCoordinate.longitude,
            altitude: 0,
            horizontalAccuracy: 0,
            verticalAccuracy: 0
        )
        return distanceMeters(center, home) <= 300
    }

    /// 타일을 추가할 때 애플 지도 스타일이면 벡터 스타일로 바꾸고, 다 붙이거나 집에서 벗어나면 원래 스타일로 되돌린다.
    /// 사용자가 그 사이에 직접 스타일을 바꿨다면 되돌리지 않는다.
    private func toggleSidebarNote(_ note: MapHomeSidebarNote) {
        sidebarNote = sidebarNote?.id == note.id ? nil : note
    }

    private func applyAutoLandStyle(near: Bool) {
        let current = model.settings.mapDisplayStyle.runtimeStyle
        if near {
            guard autoLandStyleState.isEmpty, current.mapHomeVectorStyle == nil else { return }
            let target = MapDisplayStyle.mapLibreCasual
            autoLandStyleState = "\(current.rawValue)|\(target.rawValue)"
            model.setMapDisplayStyle(target)
        } else {
            let parts = autoLandStyleState.split(separator: "|").map(String.init)
            autoLandStyleState = ""
            defer { TaptionUITheme.follow(mapStyle: model.settings.mapDisplayStyle) }
            guard parts.count == 2, parts[1] == current.rawValue,
                  let previous = MapDisplayStyle(rawValue: parts[0]) else { return }
            model.setMapDisplayStyle(previous)
        }
    }

    /// 등록지점 범위: 빨간 원은 반경, 주황 두 원은 ±15% 히스테리시스 구간.
    @ViewBuilder
    private func placeZoneOverlay(viewport: MapHomeVectorViewport?) -> some View {
        if showsPlaceRanges, let viewport, viewport.pitch < 5, mapViewportSize.height > 0 {
            let metersPerPoint = viewport.span.latitudeDelta * 111_320 / Double(mapViewportSize.height)
            if metersPerPoint.isFinite, metersPerPoint > 0 {
                ForEach(model.settings.frequentPlaces.filter { $0.point != nil }) { place in
                    if let pin = vectorPoint(in: viewport, for: vectorPlaceMarkerID(place.id)) {
                        let radius = CGFloat(place.radiusMeters / metersPerPoint)
                        let outer = CGFloat(place.radiusMeters * (1 + MapHomePlaceZone.band) / metersPerPoint)
                        let inner = CGFloat(place.radiusMeters * (1 - MapHomePlaceZone.band) / metersPerPoint)
                        ZStack {
                            Circle()
                                .stroke(Color.orange.opacity(0.85), lineWidth: 1.5)
                                .frame(width: outer * 2, height: outer * 2)
                            Circle()
                                .stroke(Color.orange.opacity(0.85), lineWidth: 1.5)
                                .frame(width: inner * 2, height: inner * 2)
                            Circle()
                                .stroke(Color.red, lineWidth: 2)
                                .frame(width: radius * 2, height: radius * 2)
                        }
                        .frame(width: 0, height: 0)
                        .opacity(0.5)
                        .position(pin)
                        .allowsHitTesting(false)
                    }
                }
            }
        }
    }

    /// 땅 한 칸의 실제 크기(m). 최대 확대(카메라 거리 80m, 1점≈0.06m) 기준으로 한 칸이 약 416pt가 된다.
    private static let landCellMeters = 25.0

    /// 집 주변에 이어 붙인 땅을 지도 위에 그린다(최대 확대에 가까울수록 크게). 붙일 땅이 남아 있으면
    /// 이을 수 있는 빈 칸이 점선 "+"로 나오고, 눌러서 이어 붙인다. 벡터 지도 스타일에서만 그린다.
    @ViewBuilder
    private func homeLandOverlay(viewport: MapHomeVectorViewport?) -> some View {
        if let layout = homeLandLayout(viewport: viewport) {
            let season = homeGrowthHistory.season
            let placements = season.landPlotPlacements ?? []
            let nextPlot = season.landPlots.first { id in !placements.contains { $0.plotID == id } }
            let candidates = nextPlot == nil ? [] : MapHomeGrowthPolicy.placementCandidates(in: season)
            ZStack {
                ForEach(placements) { placement in
                    RoundedRectangle(cornerRadius: layout.cell * 0.14, style: .continuous)
                        .fill(Color.tpPastelMint.opacity(0.55))
                        .overlay {
                            RoundedRectangle(cornerRadius: layout.cell * 0.14, style: .continuous)
                                .stroke(Color.tpReferenceMint.opacity(0.7), lineWidth: 1)
                        }
                        .frame(width: layout.cell - 2, height: layout.cell - 2)
                        .offset(x: CGFloat(placement.x) * layout.cell, y: CGFloat(placement.y) * layout.cell)
                        .allowsHitTesting(false)
                }
                ForEach(Array(candidates.enumerated()), id: \.offset) { _, cell in
                    Button {
                        placeLandFromMap(x: cell.x, y: cell.y)
                    } label: {
                        RoundedRectangle(cornerRadius: layout.cell * 0.14, style: .continuous)
                            .strokeBorder(Color.tpAccent.opacity(0.8), style: StrokeStyle(lineWidth: 1.4, dash: [5, 4]))
                            .background(Color.tpAccent.opacity(0.06), in: RoundedRectangle(cornerRadius: layout.cell * 0.14, style: .continuous))
                            .overlay {
                                Image(systemName: "plus")
                                    .font(.system(size: min(20, layout.cell * 0.32), weight: .bold))
                                    .foregroundStyle(Color.tpAccent)
                            }
                            .frame(width: layout.cell - 2, height: layout.cell - 2)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .offset(x: CGFloat(cell.x) * layout.cell, y: CGFloat(cell.y) * layout.cell)
                    .accessibilityLabel(language.text("여기에 땅 이어 붙이기", "Attach land here"))
                }
            }
            .frame(width: 0, height: 0)
            .rotationEffect(.degrees(-layout.heading))
            .position(layout.center)
        }
    }

    private struct HomeLandLayout {
        let center: CGPoint
        let cell: CGFloat
        let heading: Double
    }

    /// 집 핀의 화면 위치와 한 칸의 화면 크기. 집이 없거나 너무 멀리 있거나 기울어져 있으면 nil.
    private func homeLandLayout(viewport: MapHomeVectorViewport?) -> HomeLandLayout? {
        guard MapHomeLandFeature.isVisible,
              let viewport,
              viewport.pitch < 5,
              mapViewportSize.height > 0,
              let home = model.settings.frequentPlaces.first(where: { $0.kind == .home }),
              let pin = vectorPoint(in: viewport, for: vectorPlaceMarkerID(home.id)) else { return nil }
        let metersPerPoint = viewport.span.latitudeDelta * 111_320 / Double(mapViewportSize.height)
        guard metersPerPoint.isFinite, metersPerPoint > 0 else { return nil }
        let cell = CGFloat(Self.landCellMeters / metersPerPoint)
        // 너무 작게 보이면 그리지 않고, 화면보다 훨씬 크면 그리지 않는다.
        guard cell >= 14, cell <= 900 else { return nil }
        return HomeLandLayout(center: pin, cell: cell, heading: viewport.heading)
    }

    private func placeLandFromMap(x: Int, y: Int) {
        guard canWriteHomeGrowth else { return }
        var history = homeGrowthHistory
        guard let plotID = history.season.landPlots.first(where: { id in
            !(history.season.landPlotPlacements ?? []).contains { $0.plotID == id }
        }), MapHomeGrowthPolicy.placeLandPlot(plotID, atX: x, y: y, in: &history.season),
              let encoded = try? JSONEncoder().encode(history) else { return }
        homeGrowthData = encoded
    }

    private func vectorPlaceMarkerID(_ id: UUID) -> String {
        "place-\(id.uuidString)"
    }

    private func vectorTransitMarkerID(_ id: UUID) -> String {
        "transit-\(id.uuidString)"
    }

    private func vectorMapStickerMarkerID(_ id: UUID) -> String {
        "map-sticker-\(id.uuidString)"
    }

    private func vectorMapMemoMarkerID(_ id: UUID) -> String {
        "map-memo-\(id.uuidString)"
    }

    private func vectorBoardingCandidateMarkerID(_ id: String) -> String {
        "boarding-candidate-\(id)"
    }

    private func vectorPoint(
        in viewport: MapHomeVectorViewport?,
        for id: String
    ) -> CGPoint? {
        viewport?.markerPoints[id]
    }

    private func applyVectorMapViewport(
        _ viewport: MapHomeVectorViewport,
        isFinal: Bool
    ) {
        guard scenePhase == .active else { return }
        MapHomeHomeSkyHeading.current = viewport.heading
        MapHomeInteractionMonitor.shared.touch("map_gesture")
        let now = ProcessInfo.processInfo.systemUptime
        // 구동기 재생 중에는 화면 값을 간격마다만 관찰 값으로 올리고, 화랑이 점은 구동기가 맡는다(PLY1029A03·PLY1029A05).
        // "이동 완료"(isFinal)도 예외가 아니다: 애니메이션 없이 놓은 카메라는 매 프레임 이동 완료를 알려,
        // 예전에는 여기서 매 프레임 화면 전체를 다시 그렸다(틱 하나에 오버레이 4번, PLY1029A09).
        if playbackDriver != nil {
            vectorMapViewportStore.updateViewportThrottled(viewport, nowUptime: now)
            return
        }
        vectorMapViewportStore.update(viewport)
        let displayedPoint = viewport.markerPoints[vectorDisplayedMarkerID]
        if let displayedPoint {
            vectorMapViewportStore.updateStickmanPoint(
                displayedPoint,
                nowUptime: now
            )
        }
        let frame = MapHomeCameraFrame(
            camera: viewport.camera,
            region: viewport.region
        )
        _ = mapCameraFrameProjection.submit(
            frame,
            nowUptime: now,
            force: isFinal
        )
        if vectorMapViewportStore.shouldPublishParentReadback(
            nowUptime: now,
            isFinal: isFinal
        ), let latestFrame = mapCameraFrameProjection.latestFrame {
            applyMapCameraFrame(latestFrame, locationPoint: displayedPoint)
        }
        if isFinal {
            vectorMapViewportStore.finishStickmanPoint(nowUptime: now)
        }
    }

    private func presentMapLongPressMenu(at coordinate: CLLocationCoordinate2D) {
        mapSearchResults = []
        isMapSearchFocused = false
        isSearchExpanded = false
        pendingLongPressCoordinate = coordinate
        // 누른 자리에 핀이 먼저 꽂힌 다음 메뉴가 뜬다.
        selectedSearchPin = MapHomeSearchResult(
            title: language.text("사용자 지점", "User location"),
            subtitle: language.text("지도에서 선택한 위치", "Long-pressed map location"),
            coordinate: coordinate
        )
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(220))
            if pendingLongPressCoordinate != nil { isLongPressMenuPresented = true }
        }
    }

    private func presentLocationAddition(at coordinate: CLLocationCoordinate2D) {
        mapSearchResults = []
        isMapSearchFocused = false
        isSearchExpanded = false
        selectedSearchPin = MapHomeSearchResult(
            title: language.text("사용자 지점", "User location"),
            subtitle: language.text("지도에서 선택한 위치", "Long-pressed map location"),
            coordinate: coordinate
        )
        isSearchPinMenuPresented = true
    }

    private func routeLongPress(_ action: MapHomeLongPressAction) {
        guard let coordinate = pendingLongPressCoordinate else { return }
        pendingLongPressCoordinate = nil
        switch action {
        case .location:
            presentLocationAddition(at: coordinate)
        case .memo:
            selectedSearchPin = nil
            addMapMemo(at: coordinate)
        }
    }

    private var homeGrowthHistory: MapHomeGrowthHistory {
        growthHistoryCache.history(for: homeGrowthData) ?? .initial(for: .now)
    }

    /// 저장된 값이 있는데 읽지 못하면 초기값으로 덮어쓰지 않는다.
    private var canWriteHomeGrowth: Bool {
        homeGrowthData.isEmpty || growthHistoryCache.history(for: homeGrowthData) != nil
    }

    private func refreshHomeGrowth(at now: Date) {
        guard model.isBootstrapped, scenePhase == .active, canWriteHomeGrowth else { return }
        var history = homeGrowthHistory
        let calendar = MapHomeGrowthPolicy.localCalendar
        if let key = history.season.pendingDay,
           let day = MapHomeGrowthPolicy.date(for: key, calendar: calendar),
           calendar.startOfDay(for: day) < calendar.startOfDay(for: now) {
            history.season.pendingDayQualified = MapHomeGrowthPolicy.qualifiesDay(
                actuals: model.snapshot.actuals,
                travel: model.snapshot.travel,
                on: day,
                asOf: now,
                calendar: calendar
            )
        }
        MapHomeGrowthPolicy.closePendingDay(
            in: &history,
            asOf: now,
            calendar: calendar
        )
        if calendar.isDate(model.selectedDate, inSameDayAs: now),
           let dayData = currentDayDataSnapshot {
            MapHomeGrowthPolicy.observeCurrentDay(
                in: &history,
                date: now,
                qualified: MapHomeGrowthPolicy.qualifiesDay(
                    actuals: dayData.actuals,
                    travel: dayData.travel,
                    on: now,
                    asOf: now,
                    calendar: calendar
                ),
                calendar: calendar
            )
        }
        guard let encoded = try? JSONEncoder().encode(history),
              encoded != homeGrowthData else { return }
        homeGrowthData = encoded
    }

    private func rewardRecentCompletedDay(_ day: Date, asOf now: Date = .now) {
        guard canWriteHomeGrowth else { return }
        let calendar = MapHomeGrowthPolicy.localCalendar
        let actuals = model.snapshot.actuals
        let travel = model.snapshot.travel
        var history = homeGrowthHistory
        if let key = history.season.pendingDay,
           let pendingDate = MapHomeGrowthPolicy.date(for: key, calendar: calendar),
           calendar.startOfDay(for: pendingDate) < calendar.startOfDay(for: now) {
            history.season.pendingDayQualified = MapHomeGrowthPolicy.qualifiesDay(
                actuals: model.snapshot.actuals,
                travel: model.snapshot.travel,
                on: pendingDate,
                asOf: now,
                calendar: calendar
            )
        }
        MapHomeGrowthPolicy.settleAndAwardRecentCompletion(
            in: &history,
            day: day,
            asOf: now,
            qualified: MapHomeGrowthPolicy.qualifiesDay(
                actuals: actuals,
                travel: travel,
                on: day,
                asOf: now,
                calendar: calendar
            ),
            calendar: calendar
        )
        guard let encoded = try? JSONEncoder().encode(history),
              encoded != homeGrowthData else { return }
        homeGrowthData = encoded
    }

    /// 하루 카드 알림을 누르면 그 카드를 연다. 오전(12시 전) 알림은 전날, 그 밖의 시각은 알림이 온 날을 보여 준다(자정 전이면 나머지는 미확인).
    private func openDailyCardFromAlarm(fireDate: Date) {
        let calendar = Calendar.autoupdatingCurrent
        let hour = calendar.component(.hour, from: fireDate)
        let day = calendar.startOfDay(for: fireDate)
        let target = hour < 12 ? (calendar.date(byAdding: .day, value: -1, to: day) ?? day) : day
        model.selectedDate = target
        isDailyCardPresented = true
    }

    /// 알람 확인 시트에 넘길 항목(알람을 누르면 채워지고, 닫으면 비워진다).
    private var alarmConfirmBinding: Binding<AlarmConfirmItem?> {
        Binding<AlarmConfirmItem?>(
            get: {
                guard let pending = pendingAlarm else { return nil }
                return AlarmConfirmItem(kind: pending.kind, at: pending.at)
            },
            set: { value in
                if value == nil { pendingAlarm = nil }
            }
        )
    }

    /// 연봉 카운터 작업을 다시 돌릴 기준값. 식이 길어 따로 뺐다.
    private var salaryTaskID: String {
        let parts: [String] = [
            "\(salaryAnnualPay)", "\(salaryMonthlyPay)", "\(salaryIsNetInput)", "\(salaryShowsNet)",
            "\(salaryMonthAccum)", "\(salaryPayHistoryRaw)", "\(scenePhase == .active)",
            "\(model.selectedDate.timeIntervalSince1970)", "\(model.snapshot.actuals.count)", "\(model.snapshot.places.count)",
        ]
        return parts.joined(separator: "|")
    }

    /// 선택한 날의 메모 수: 시각이 있는 메모는 그 날짜, 시각이 없는 메모는 만든 날짜로 센다. 지도에 찍은 메모는 따로 센다.
    private var dayMemoCounts: (total: Int, map: Int) {
        let calendar = Calendar.autoupdatingCurrent
        let start = calendar.startOfDay(for: model.selectedDate)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        let memos = model.snapshot.memos.filter { memo -> Bool in
            let when: Date = (memo.isTimeless == true) ? memo.createdAt : memo.occurredAt
            return when >= start && when < end
        }
        return (memos.count, memos.filter { $0.mapPoint != nil }.count)
    }

    /// 선택한 날의 달력 항목 값(항목 id → 값). 공유 카드의 항목 고르기와 카드 값에 쓴다.
    private var dailyMetricValues: [String: Double] {
        let calendar = Calendar.autoupdatingCurrent
        let start = calendar.startOfDay(for: model.selectedDate)
        let snap = currentDayDataSnapshot
        let placeKinds = FrequentPlaceResolutionEngine().kindsByPlaceKey(model.snapshot.settings.frequentPlaces)
        var values = MapHomeCalendarTimeTotalsPolicy.totals(
            actuals: snap?.actuals ?? [], travel: snap?.travel ?? [], stays: snap?.places ?? [],
            placeKinds: placeKinds, month: start, asOf: .now, calendar: calendar,
            sealed: model.sealedDays
        )[start] ?? [:]
        if let steps = dayStepCount {
            values[MapHomeCalendarTimeKind.steps.rawValue] = Double(steps)
        }
        return values
    }

    /// 선택한 날이 자정까지 지나서 끝까지 관측됐는지. 아니면 카드의 나머지 시간은 미확인으로 표시한다.
    private var isDayObservedToEnd: Bool {
        let calendar = Calendar.autoupdatingCurrent
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: model.selectedDate)) ?? .now
        return Date.now >= dayEnd
    }

    /// 오늘로 가서 전체 경로를 화면에 맞춘다(날짜 배지 더블탭).
    private func jumpToTodayAndFitRoutes() {
        isDateWeekExpanded = false
        jumpToTodayAndCurrentMapPosition()
        // 날짜를 바꾸면 경로 데이터가 늦게 들어오므로, 불러온 뒤 한 번 더 전체 경로를 화면에 맞춘다.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            guard !isDayPlaybackRunning else { return }
            focusMapOnAllRoutes()
        }
    }

    /// 하루 카드 데이터: 선택한 날짜의 대분류·걸음·이동·번 돈.
    private var dailyCardData: MapHomeDailyCardData {
        let categories = daySummaryCategories
        let total = categories.reduce(0) { $0 + $1.seconds }
        let travel = MapHomeDayTravelSummary.entries(from: currentDayDataSnapshot?.travel ?? [])
        let distance = travel.reduce(0) { $0 + $1.meters }
        let earned = salaryLive.map {
            MapHomeSalaryPolicy.earnings(workSeconds: MapHomeSalaryPolicy.liveWorkSeconds(
                base: $0.todayWorkSeconds, baseDate: $0.measuredAt, isWorking: false, now: .now, tick: 1
            ), hourlyRate: $0.hourlyRate)
        }
        let work = categories.first { $0.id == MapHomeSalaryPolicy.workKey }?.seconds
        return MapHomeDailyCardData(
            dateText: model.selectedDate.formatted(Date.FormatStyle().month().day().locale(language.locale)),
            weekdayText: model.selectedDate.formatted(Date.FormatStyle().weekday(.wide).locale(language.locale)),
            earnedText: earned.map { MapHomeSalaryPolicy.wonText($0, language: language) },
            workText: work.map(MapHomeAlarmPolicy.hoursText),
            steps: dayStepCount,
            distanceText: distance > 0 ? MapHomeDayTravelSummary.distanceText(distance) : nil,
            categories: categories,
            totalText: language.text(
                "관측 \(MapHomeAlarmPolicy.hoursText(total))" + (isDayObservedToEnd ? "" : " · 나머지는 미확인"),
                "Observed \(MapHomeAlarmPolicy.hoursText(total))" + (isDayObservedToEnd ? "" : " · rest unconfirmed")
            ),
            accessoryID: homeGrowthHistory.season.equippedAccessory,
            memoText: dayMemoCounts.total > 0
                ? language.text("메모 \(dayMemoCounts.total)개 · 지도 \(dayMemoCounts.map)개", "Memos \(dayMemoCounts.total) · map \(dayMemoCounts.map)")
                : nil,
            routePoints: daySummaryRoutePoints,
            homeLevel: homeGrowthHistory.season.level
        )
    }

    /// 하루 카드 한 장. 지도가 보는 날은 읽어 둔 값을, 다른 날은 그날 기록을 따로 읽어 만든다(지도 날짜는 그대로 둔다).
    private func dailyCardContent(for day: Date) async -> MapHomeDailyCardContent {
        if Calendar.autoupdatingCurrent.isDate(day, inSameDayAs: model.selectedDate) {
            return MapHomeDailyCardContent(data: dailyCardData, values: dailyMetricValues)
        }
        let snapshot = await model.planDayDataSnapshot(for: day, forceReload: false)
        return MapHomeDailyCardContent.make(
            day: day,
            snapshot: snapshot,
            sealedDays: model.sealedDays,
            placeKinds: FrequentPlaceResolutionEngine().kindsByPlaceKey(model.snapshot.settings.frequentPlaces),
            hourlyRate: salaryLive?.hourlyRate,
            accessoryID: homeGrowthHistory.season.equippedAccessory,
            homeLevel: homeGrowthHistory.season.level,
            memos: model.snapshot.memos,
            language: language,
            entries: { daySummaryEntries(from: $0) }
        )
    }

    /// 요약 카드에 그릴 경로. 확정한 날은 저장해 둔 단순화 경로를 쓴다(센서 원본을 다시 읽지 않는다).
    private var daySummaryRoutePoints: [GeoPoint] {
        if let sealed = model.sealedDay(for: model.selectedDate), !sealed.polyline.isEmpty {
            return sealed.routePoints
        }
        return currentDayReadings.compactMap { reading in
            reading.point.map {
                GeoPoint(
                    latitude: $0.latitude,
                    longitude: $0.longitude,
                    altitude: 0,
                    horizontalAccuracy: 0,
                    verticalAccuracy: 0
                )
            }
        }
    }

    private var dayStepCount: Int? {
        // 지나간 날은 확정 요약의 걸음 수를 쓴다(센서 원본을 다시 읽지 않는다).
        if let sealed = model.sealedDay(for: model.selectedDate), sealed.stepCount > 0 { return sealed.stepCount }
        return MapHomeCounterTimelinePolicy.stepCount(readings: currentDayReadings, cutoff: nil)
    }

    /// 하루를 대분류(수면·업무·이동·식사·취미·운동 등)로 묶은 요약. 세부 기록
    /// 원본(actuals)은 그대로 두고 파생 집계만 만든다. 비중은 관측된 총 시간
    /// 대비로 계산해 합이 100%가 되게 한다.
    private var daySummaryCategories: [MapHomeDaySummaryEntry] {
        daySummaryEntries(from: daySummaryCategorySeconds(asOf: nil))
    }

    /// 대분류별 초. `cutoff`를 넘기면 그 시각까지로 잘라 센다(재생 중 카운터가 시간을 따라 올라간다).
    /// 멈춰 있을 때(`cutoff == nil`)는 `now`까지로 센다 — 창의 시계가 10초마다 넘겨 주는
    /// 그 순간이라, 진행 중인 활동이 분 단위로 올라간다.
    private func daySummaryCategorySeconds(asOf cutoff: Date?, now: Date = .now) -> [String: TimeInterval] {
        // 확정한 날은 저장해 둔 대분류별 초를 그대로 쓴다(다시 계산하지 않는다).
        if cutoff == nil,
           let sealed = model.sealedDay(for: model.selectedDate),
           !sealed.categorySeconds.isEmpty {
            return sealed.categoryDurations
        }
        let snap = displayDayDataSnapshot
        let actuals = snap?.actuals ?? []
        let travel = snap?.travel ?? []
        let stays = snap?.places ?? []
        let placeKinds = FrequentPlaceResolutionEngine().kindsByPlaceKey(
            model.snapshot.settings.frequentPlaces
        )
        let calendar = Calendar.autoupdatingCurrent
        let start = calendar.startOfDay(for: model.selectedDate)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(24 * 60 * 60)
        let dayWindow = TimeSpan(start: start, end: end)
        let totalsByID = TaptionSealedDayBuilder.categoryDurations(
            actuals: actuals,
            travel: travel,
            stays: stays,
            placeKinds: placeKinds,
            day: dayWindow,
            asOf: cutoff ?? now
        )
        // 재생 시각으로 잘라 내려면 원본이 있어야 한다. 없으면 저장해 둔 확정값으로 물러선다.
        if totalsByID.isEmpty, let sealed = model.sealedDay(for: model.selectedDate) {
            return sealed.categoryDurations
        }
        return totalsByID
    }

    private func daySummaryEntries(from totalsByID: [String: TimeInterval]) -> [MapHomeDaySummaryEntry] {
        let total = totalsByID.values.reduce(0) { $0 + max(0, $1) }
        guard total > 0 else { return [] }
        return totalsByID
            .filter { $0.value > 0 }
            .map { id, seconds in
                let presentation = MapHomeSidebarMajorCategory.presentation(
                    for: id,
                    categoryColors: model.settings.mapCategoryColors
                )
                return MapHomeDaySummaryEntry(
                    id: id,
                    title: presentation.localizedTitle(language),
                    systemImage: presentation.systemImage,
                    tint: presentation.tint,
                    seconds: seconds,
                    ratio: seconds / total
                )
            }
            .sorted { $0.seconds > $1.seconds }
    }

    /// 겹치는 구간을 병합해 총 소요 시간을 반환한다(같은 초 중복 계산 방지).
    private static func unionDuration(_ spans: [TimeSpan]) -> TimeInterval {
        let ordered = spans
            .filter { $0.duration > 0 }
            .sorted { $0.start < $1.start }
        guard var current = ordered.first else { return 0 }
        var total: TimeInterval = 0
        for span in ordered.dropFirst() {
            if span.start <= current.end {
                current.end = max(current.end, span.end)
            } else {
                total += current.duration
                current = span
            }
        }
        return total + current.duration
    }

    /// 하단 메뉴 고정: 홈 배치는 하단 탭으로 고정한다(선택 메뉴 제거).
    private var layoutStyle: MapHomeLayoutStyle { .tabBar }

    /// 저장된 안개 세기. 알 수 없는 값이면 옅게로 돌아간다.
    private var fogStrength: MapHomeFogStrength {
        MapHomeFogStrength(rawValue: fogStrengthRaw) ?? .light
    }

    /// 재생 HUD가 쓰는 종료 분. 오늘이면 지금 시각, 지난 날이면 하루 끝(1440)이다.
    private var playbackHUDEndMinute: Double {
        MapHomeDayPlaybackMath.playbackEndMinute(for: model.selectedDate, now: .now)
    }

    private func openMenu() {
        isLocationMenuExpanded = false
        isUserLocationsMenuExpanded = false
        isCategoryMenuExpanded = false
        isDisplayMenuExpanded = false
        isCounterMenuExpanded = false
        isSidebarGroupExpanded = false
        isMapGroupExpanded = false
        isSettingsMenuExpanded = false
        isGPSLoggingMenuExpanded = false
        withAnimation(.easeInOut(duration: 0.22)) { isMenuOpen = true }
    }

    /// 안내 알림에서 바로 메뉴 > 위치를 연다. 알림이 말한 목적지로 데려간다.
    private func openLocationSettings() {
        openMenu()
        isLocationMenuExpanded = true
    }

    /// 하단 탭·떠 있는 독. 1급 항목은 일곱 개이고 **맨 왼쪽이 메뉴**다.
    ///
    /// 메뉴는 2026-10-26까지 왼쪽 위 원형 단추였다. 지도와 날짜 줄을 가리고,
    /// 손이 닿지 않는 구석이라 아래로 내렸다(대표 요청). 항목은 늘리지 않았다.
    private var bottomActionBar: some View {
        HStack(spacing: 0) {
            bottomBarButton("line.3.horizontal", language.text("메뉴", "Menu")) {
                if isMenuOpen { isMenuOpen = false } else { openMenu() }
            }
            MapHomeBottomBarButton(title: language.text("달력", "Calendar"), action: { isCalendarPresented.toggle() }) {
                MapHomeCalendarGlyph(date: model.selectedDate, language: language)
            }
            bottomBarButton("location.fill", language.text("현재 위치", "Location")) {
                // 날짜를 오늘로 맞추는 일은 requestAndFollowUserLocation이 함께 한다.
                requestAndFollowUserLocation(using: nil, fixedScale: true)
            }
            // 하단 가운데 집 버튼: 지도를 집으로 옮기고 땅 타일이 보이는 배율까지 확대한다(요약·성장 시트는 지도의 집 아이콘).
            bottomBarButton("house.fill", language.text("집", "Home")) {
                // 집이 없으면 focusMapOnHome이 안내만 띄우므로 요약은 열지 않는다.
                guard model.settings.frequentPlaces.contains(where: { $0.kind == .home && $0.point != nil }) else {
                    focusMapOnHome()
                    return
                }
                focusMapOnHome()
                // 집으로 옮긴 뒤 하루 요약을 바로 연다.
                isDaySummaryPresented = true
            }
            // 재생 중에는 **같은 자리에서** 「멈춤」으로만 바뀐다. 예전에는
            // 「일시 정지」와 「종료」를 나란히 두어 하단 항목이 하나 늘었는데,
            // 재생을 끝내려는 사람이 두 단추를 헷갈렸다(대표 요청: 단추를 늘리지 말 것).
            if isDayPlaybackRunning {
                bottomBarButton("pause.fill", language.text("멈춤", "Pause")) {
                    toggleDayPlayback()
                }
            } else {
                bottomBarButton("play.fill", language.text("재생", "Play")) {
                    startDayPlayback()
                }
            }
            // 녹화는 재생 바로 옆에 둔다. 재생을 마친 사람이 다음에 누르는 버튼이라
            // 메뉴 안으로 옮기면 찾지 못한다(0f2987d에서 내렸다가 되돌림).
            bottomBarButton("record.circle", language.text("녹화", "Record")) {
                openRecordingOptions()
            }
            bottomBarButton("plus", language.text("메모", "Memo")) {
                addMemo()
            }
        }
        .padding(.horizontal, 8)
        .mapHomeBottomBarPill()
    }

    private func bottomBarButton(
        _ icon: String,
        _ title: String,
        action: @escaping () -> Void
    ) -> some View {
        MapHomeBottomBarButton(title: title, action: action) {
            TaptionBarIcon(systemImage: icon)
        }
    }

    /// 오른쪽 위 날짜 배지: 요일(토 파랑, 일·공휴일 빨강)과 큰 날짜.
    /// 누르면 앞뒤 날짜가 이어지는 날짜 줄을 펼친다. 그 줄을 좌우로 밀면 하루씩 넘어간다.
    /// 접힌 사이드바를 펼치는 화살표. 날짜 배지와 한 알약에 붙어 있다(숨김 상태에서는 아래 화살표).
    private var sidebarExpandArrow: some View {
        Button {
            withAnimation(MapHomeView.sidebarToggleSpring) { isSidebarVisible = true }
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .bold))
                .foregroundStyle(Color.tpInk.opacity(0.85))
                .frame(width: 26, height: 26)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(language.text("사이드바 펼치기", "Show sidebar"))
        .accessibilityIdentifier("mapHomeSidebarExpandButton")
    }

    private var dateBadge: some View {
        let info = MapHomeDateBadgeInfo.resolve(date: model.selectedDate, localeIdentifier: language.text("ko_KR", "en_US"))
        let color: Color = info.isHoliday || info.weekday == 1 ? .tpSundayText : (info.weekday == 7 ? .tpSaturdayText : .tpInk)
        let face = VStack(spacing: 0) {
            Text(info.weekdayText)
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(9)), weight: .semibold))
                .foregroundStyle(color)
            Text(String(info.day))
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(17)), weight: .bold))
                .foregroundStyle(Color.tpInk)
                .monospacedDigit()
        }
        .frame(width: timeRailWidth, height: Layout.dateBadgeSize)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        // 한 번 탭하면 날짜 줄을 왼쪽으로 펼친다.
        .onTapGesture { handleDateBadgeTap() }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: moveDate(by: 1)
            case .decrement: moveDate(by: -1)
            @unknown default: break
            }
        }
        .accessibilityLabel(language.text("날짜 \(dateTitle)", "Date \(dateTitle)"))
        .accessibilityHint(language.text("한 번 누르면 날짜 줄을 펼칩니다", "Tap to show the date strip"))
        // 화면 시험에서 이 배지를 이름으로 집는다. 날짜가 든 이름은 날마다 달라진다.
        .accessibilityIdentifier("mapHomeDateBadge")
        // 사이드바가 접혀 있으면 아래에 펼치기 화살표를 붙여 날짜 배지와 한 알약으로 묶는다. 펼친 날짜 줄 동안에는 숨긴다.
        let showsArrow = !isSidebarVisible && !isDateWeekExpanded
        let isPlain = !showsArrow
        let badge = VStack(spacing: 2) {
            face
            if showsArrow {
                sidebarExpandArrow
            }
        }
        .padding(.vertical, isPlain ? 0 : 4)
        .frame(width: timeRailWidth)
        .mapHomeGlass(in: RoundedRectangle(cornerRadius: isPlain ? 18 : 22, style: .continuous))
        .taptionHitOutset(vertical: isPlain ? max(0, (TaptionMenuMetrics.minimumHitSize - Layout.dateBadgeSize) / 2) : 0)
        return HStack(alignment: .top, spacing: 6) {
            if isDateWeekExpanded {
                MapHomeDateStrip(
                    language: language,
                    selectedDate: model.selectedDate,
                    markedDays: dataDayStarts
                ) { day in
                    shouldFitRoutesAfterDateChange = true
                    model.selectedDate = day
                }
                .frame(maxWidth: MapHomeWideLayoutPolicy.dateStripMaximumWidth(viewportWidth: mapViewportSize.width))
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
            badge
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: Calendar.autoupdatingCurrent.isDateInToday(model.selectedDate))
    }

    /// 화랑이가 실제로 그려지는 화면 점. 집에 있으면 집 핀(아바타 중심)이고, 아니면 위치 점이다.
    /// 집에 있을 때 위치 점은 집 반경 안 어딘가라 화랑이와 수십 pt 어긋날 수 있다(TAP1031A01 기기 로그).
    /// Apple 지도의 점은 걷는 화랑이 좌표(집에 있으면 집 핀)로 이미 투영돼 있다. 벡터 저장소의 점은
    /// 벡터 지도에서만 유효하므로 Apple 지도에서는 읽지 않는다(지난 재생 값이 남아 엉뚱한 곳을 가리킨다).
    private var displayedCatViewportPoint: CGPoint? {
        guard rendersVectorMap else { return displayedStickmanViewportPoint }
        if isDisplayedCatAtHome,
           let home = model.settings.frequentPlaces.first(where: { $0.kind == .home }),
           let viewport = vectorMapViewportStore.viewport,
           let pin = vectorPoint(in: viewport, for: vectorPlaceMarkerID(home.id)) {
            return pin
        }
        return vectorMapViewportStore.livePoint
            ?? vectorMapViewportStore.stickmanPoint
            ?? displayedStickmanViewportPoint
    }

    /// 화랑이의 손쉬운 사용 요소. 손가락 터치는 받지 않는다. 여기 닿은 손가락이 지도 핀치에서 빠지기 때문이다(대표 지시).
    /// 탭은 지도 탭(`handleMapTap`)이 위치로 판정한다.
    @ViewBuilder
    private var stickmanTapTarget: some View {
        if let point = displayedCatViewportPoint {
            let atHome = isDisplayedCatAtHome
            // 지도 로컬 점을 뷰포트 공간으로 옮겨 놓는다(이 층은 뷰포트 공간에 있다).
            let center = viewportPoint(fromMapLocal: atHome ? point : MapHomeCatTapRouting.markerPoint(locationPoint: point, isAtHome: false))
            let size: CGFloat = atHome
                ? MapHomePlacePinLayout.avatarSize
                : MapHomeStickmanMarker.size.width + 8
            Color.clear
                .frame(width: size, height: size)
                .contentShape(Circle())
                .position(x: center.x, y: center.y)
                .allowsHitTesting(false)
                .accessibilityElement()
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(language.text("화랑이 하루 요약", "Today summary"))
                .accessibilityAction { presentDaySummary(fromCat: true) }
        }
    }

    /// 하루 요약을 연다. 화랑이에서 열면 시트가 올라올 때 집이 아니라 화랑이를 화면에 남긴다.
    private func presentDaySummary(fromCat: Bool) {
        daySummaryFocusesCat = fromCat
        isDaySummaryPresented = true
    }

    /// 메모나 계획이 있는 날(하루의 시작 시각). 날짜 줄에 점으로 보여 준다.
    private var dataDayStarts: Set<Date> {
        let calendar = Calendar.autoupdatingCurrent
        var days = Set(model.snapshot.memos.map {
            calendar.startOfDay(for: $0.isTimeless == true ? $0.createdAt : $0.occurredAt)
        })
        days.formUnion(model.snapshot.plans.map { calendar.startOfDay(for: $0.span.start) })
        return days
    }

    /// 사이드바를 펼치고 접는 튕김. 펼칠 때는 위에서 아래로 쫙 내려오고, 접을 때는 아래부터 위로 줄어든다.
    static let sidebarToggleSpring = Animation.spring(response: 0.5, dampingFraction: 0.62)

    /// 오늘이 아니면 한 번 눌러 오늘로 돌아가고, 오늘이면 옆으로 날짜 줄을 펼친다.
    private func handleDateBadgeTap() {
        if !Calendar.autoupdatingCurrent.isDateInToday(model.selectedDate) {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { jumpToTodayAndFitRoutes() }
            return
        }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { isDateWeekExpanded.toggle() }
    }

    private var header: some View {
        HStack(spacing: 3) {


            Button {
                jumpToTodayAndCurrentMapPosition()
            } label: {
                (isHeadingMode ? datePartTitleLabel : dateTitleLabel)
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)
                    .layoutPriority(1)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                language.text("오늘 날짜로 이동", "Go to today") + ", \(dateTitle)"
            )



            if !layoutStyle.movesActionsToBottom {
                Button {
                    openRecordingOptions()
                } label: {
                    Image(systemName: "record.circle")
                        .font(.system(size: TaptionType.scaled(TaptionType.snapped(14)), weight: .bold))
                        .frame(width: 34, height: Layout.headerHitTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(language.text("재생 화면 녹화", "Record playback"))
            }

        }
        .foregroundStyle(ink)
        .padding(.horizontal, 7)
        .fixedSize(horizontal: true, vertical: false)
        .frame(height: Layout.headerVisibleHeight)
        .background(Color.tpSurface.opacity(0.96), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.tpLine.opacity(0.78), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.07), radius: 9, y: 3)
        .simultaneousGesture(
            SpatialTapGesture().onEnded { _ in
                dismissMapSearchOverlay()
            }
        )
        .onGeometryChange(
            for: CGRect.self,
            of: { proxy in
                proxy.frame(in: .named("mapHomeViewport"))
            },
            action: { frame in
                guard headerFrame != frame else { return }
                headerFrame = frame
            }
        )
    }

    private var mapSearchBar: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(
                    language.text("장소·주소 검색", "Search places or addresses"),
                    text: $mapSearchText
                )
                .focused($isMapSearchFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit { searchMap() }
                .onChange(of: mapSearchText) { _, value in
                    guard isMapSearchFocused else { return }
                    mapSearchResults = []
                    mapSearchCompleter.update(
                        query: value,
                        region: mapSearchRegion
                    )
                }
                .onChange(of: isMapSearchFocused) { _, focused in
                    if focused {
                        isSearchExpanded = true
                        mapSearchCompleter.update(
                            query: mapSearchText,
                            region: mapSearchRegion
                        )
                    } else if mapSearchText.isEmpty
                        && mapSearchResults.isEmpty
                        && selectedSearchPin == nil {
                        isSearchExpanded = false
                    }
                }
                if !mapSearchText.isEmpty || !mapSearchResults.isEmpty || selectedSearchPin != nil {
                    Button {
                        clearMapSearch()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            // 그림은 17pt라 그대로 두면 손가락이 닿지 않는다. 누름 영역만 넓힌다.
                            .taptionHitOutset(horizontal: 14, vertical: 14)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(language.text("검색 지우기", "Clear search"))
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 42)
            .background(Color.tpSurface.opacity(0.96), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.tpLine.opacity(0.78), lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(0.07), radius: 9, y: 3)
            .onGeometryChange(
                for: CGRect.self,
                of: { proxy in
                    proxy.frame(in: .named("mapHomeViewport"))
                },
                action: { frame in
                    guard searchFieldFrame != frame else { return }
                    searchFieldFrame = frame
                }
            )

            if hasMapSearchResults {
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if mapSearchResults.isEmpty {
                            ForEach(
                                Array(mapSearchCompleter.results.enumerated()),
                                id: \.offset
                            ) { _, completion in
                                mapSearchRow(
                                    title: completion.title,
                                    subtitle: completion.subtitle
                                ) {
                                    searchMap(completion: completion)
                                }
                            }
                        } else {
                            ForEach(mapSearchResults) { result in
                                mapSearchRow(
                                    title: result.title,
                                    subtitle: result.subtitle
                                ) {
                                    selectSearchResult(result)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(
                    height: MapHomeSearchLayoutMath.searchResultsHeight(
                        resultCount: mapSearchResultCount
                    ),
                    alignment: .top
                )
                .background(Color.tpSurface)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.tpLine.opacity(0.7), lineWidth: 1)
                }
                .contentShape(Rectangle())
            }
        }
        .frame(
            width: mapSearchWidth,
            height: mapSearchSurfaceHeight,
            alignment: .top
        )
    }

    private var dayPlaybackButton: some View {
        Button {
            toggleDayPlayback()
        } label: {
            Image(systemName: isDayPlaybackRunning ? "pause.fill" : "play.fill")
                .font(.system(size: MapHomeSearchLayoutMath.playbackIconSize, weight: .bold))
                .foregroundStyle(Color.tpInk)
                .frame(
                    width: MapHomeSearchLayoutMath.playbackVisualSize,
                    height: MapHomeSearchLayoutMath.playbackVisualSize
                )
                .background(Color.tpSurface.opacity(0.96), in: Circle())
                .overlay {
                    Circle().stroke(Color.tpLine.opacity(0.78), lineWidth: 1)
                }
                .shadow(color: Color.black.opacity(0.07), radius: 9, y: 3)
                .frame(
                    width: MapHomeSearchLayoutMath.playbackTouchSize,
                    height: MapHomeSearchLayoutMath.playbackTouchSize
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            isDayPlaybackRunning
                ? language.text("하루 재생 일시 정지", "Pause day playback")
                : language.text("하루 재생", "Play day")
        )
    }

    private func mapStyleTitle(_ style: MapDisplayStyle) -> String {
        switch style {
        case .standard: language.text("애플맵", "Apple Maps")
        case .hybrid: language.text("위성", "Satellite")
        // 스타일 이름은 재질이 아니라 상황으로 적는다. "벡터 야간"을 고르려는 사람은 없다.
        case .mapLibreNight: language.text("야간", "Night")
        case .mapLibreContrast: language.text("실외(고대비)", "Outdoor (high contrast)")
        case .mapLibreCasual: language.text("계절", "Seasons")
        case .mapLibreRPG: language.text("판타지 지도", "Fantasy Map")
        }
    }

    private func mapStyleSystemImage(_ style: MapDisplayStyle) -> String {
        switch style {
        case .standard: "map"
        case .hybrid: "globe.asia.australia.fill"
        case .mapLibreNight: "moon.stars.fill"
        case .mapLibreContrast: "circle.lefthalf.filled"
        case .mapLibreCasual: "leaf.fill"
        case .mapLibreRPG: "map.circle.fill"
        }
    }

    private func mapSearchRow(
        title: String,
        subtitle: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "mappin.and.ellipse")
                    .font(.system(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .semibold))
                    .foregroundStyle(Color.tpReferenceBlue)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .semibold))
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .regular))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(minHeight: MapHomeSearchLayoutMath.searchRowHeight)
        }
        .buttonStyle(.plain)
    }

    private var mapSearchRegion: MKCoordinateRegion {
        let center = currentCoordinate ?? visibleMapCenter
        let span = visibleMapSpan.latitudeDelta > 0 && visibleMapSpan.longitudeDelta > 0
            ? visibleMapSpan
            : MKCoordinateSpan(latitudeDelta: 0.25, longitudeDelta: 0.25)
        return MKCoordinateRegion(center: center, span: span)
    }

    private func dismissMapSearchOverlay() {
        if isSearchPinMenuPresented, selectedSearchPin != nil {
            cancelPendingMapLocationAddition()
            return
        }
        guard isMapSearchFocused
                || !mapSearchResults.isEmpty
                || !mapSearchCompleter.results.isEmpty
        else { return }
        isMapSearchFocused = false
        isSearchExpanded = false
        mapSearchResults = []
        mapSearchCompleter.clear()
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }

    private func cancelPendingMapLocationAddition() {
        pendingUserLocationSelection = nil
        selectedSearchPin = nil
        isSearchPinMenuPresented = false
    }

    private func clearMapSearch() {
        mapSearchTask?.cancel()
        mapSearchTask = nil
        mapSearchRequestID = UUID()
        mapSearchCompleter.clear()
        mapSearchText = ""
        mapSearchResults = []
        selectedSearchPin = nil
        isSearchPinMenuPresented = false
        isMapSearchFocused = false
        isSearchExpanded = false
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }

    private func searchMap() {
        let query = mapSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            mapSearchResults = []
            return
        }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.region = mapSearchRegion
        runMapSearch(request, fallbackTitle: query)
    }

    private func searchMap(completion: MKLocalSearchCompletion) {
        let request = MKLocalSearch.Request(completion: completion)
        request.region = mapSearchRegion
        runMapSearch(request, fallbackTitle: completion.title)
    }

    private func runMapSearch(
        _ request: MKLocalSearch.Request,
        fallbackTitle: String
    ) {
        mapSearchTask?.cancel()
        let requestID = UUID()
        mapSearchRequestID = requestID
        mapSearchTask = Task { @MainActor in
            guard let response = try? await MKLocalSearch(request: request).start(),
                  !Task.isCancelled,
                  requestID == mapSearchRequestID
            else { return }
            let results = response.mapItems.prefix(8).map { item in
                MapHomeSearchResult(
                    title: item.name ?? fallbackTitle,
                    subtitle: item.placemark.title ?? "",
                    coordinate: item.placemark.coordinate
                )
            }
            mapSearchCompleter.clear()
            if let first = results.first {
                selectSearchResult(first)
            } else {
                mapSearchResults = []
            }
        }
    }

    private func selectSearchResult(_ result: MapHomeSearchResult) {
        focusMap(
            on: GeoPoint(
                latitude: result.coordinate.latitude,
                longitude: result.coordinate.longitude,
                altitude: 0,
                horizontalAccuracy: -1,
                verticalAccuracy: -1
            )
        )
        selectedSearchPin = result
        mapSearchResults = []
        mapSearchCompleter.clear()
        isMapSearchFocused = false
        isSearchExpanded = false
        mapSearchText = result.title
    }

    private func headerDateButton(_ icon: String, amount: Int) -> some View {
        Button {
            moveDate(by: amount)
        } label: {
            Group {
                if let assetName = headerIconAssetName(for: icon) {
                    Image(assetName)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 18, height: 18)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: TaptionType.scaled(TaptionType.snapped(18)), weight: .medium))
                }
            }
                .frame(width: 31, height: Layout.headerHitTarget)
        }
        .accessibilityLabel(
            amount < 0
                ? language.text("이전 날짜", "Previous date")
                : language.text("다음 날짜", "Next date")
        )
    }

    private func headerIconAssetName(for systemImage: String) -> String? {
        switch systemImage {
        case "chevron.backward.2": "MapHomeNavigatePreviousDouble"
        case "chevron.left": "MapHomeNavigatePrevious"
        case "chevron.right": "MapHomeNavigateNext"
        case "chevron.forward.2": "MapHomeNavigateNextDouble"
        default: nil
        }
    }

    private func loadPhotoMoments(asksPermission: Bool) async {
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

    private var photoClusters: [MapHomePhotoCluster] {
        guard showsPhotosOnMap, !photoMoments.isEmpty, recordingShows(\.photos) else { return [] }
        let radius = MapHomePhotoPolicy.clusterRadiusMeters(cameraDistance: visibleMapCamera?.distance)
        return photoClusterCache.clusters(for: photoMoments, radiusMeters: radius)
    }

    /// 핀에 보일 대표 사진·개수·강조 여부. 재생 중에는 지나온 사진만 순서대로 나타난다.
    private func photoPinInfo(for cluster: MapHomePhotoCluster) -> (coverID: String, count: Int, highlighted: Bool)? {
        if isDayPlaybackRunning {
            let minute = dayPlaybackCurrentMinute ?? Double(effectiveTimelineMinute)
            let visible = MapHomePhotoPolicy.playbackVisibleMoments(in: cluster, playbackMinute: minute)
            guard let cover = visible.last else { return nil }
            return (cover.id, visible.count, true)
        }
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

    private func vectorPhotoMarkerID(_ id: String) -> String { "photo-\(id)" }

    /// 재생 중에는 화랑이를 피하지 않는다. 핀이 프레임마다 자리를 옮기게 된다.
    private func photoPinPoint(_ cluster: MapHomePhotoCluster, in viewport: MapHomeVectorViewport?, places: [MapHomePlaceAnnotation]) -> CGPoint? {
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

    private var recordingLayers: MapHomeRecordingLayers {
        MapHomeRecordingLayers(rawValue: recordingLayersRaw)
    }

    /// 녹화 중에는 고른 레이어만 보이고, 녹화 중이 아니면 항상 보인다.
    private func recordingShows(_ layer: KeyPath<MapHomeRecordingLayers, Bool>) -> Bool {
        if layer == \MapHomeRecordingLayers.routes, !showsRoutesOnMap { return false }
        if layer == \MapHomeRecordingLayers.footprints, !showsFootprintsOnMap { return false }
        return !isScreenRecording || recordingLayers[keyPath: layer]
    }

    /// 달력 지표 합계. 사진 수는 비싸고 천천히 바뀌어 `includePhotos`가 true일 때만 읽는다.
    private func calendarTimeTotals(month: Date, includePhotos: Bool) async -> [Date: [String: TimeInterval]] {
        let actuals = model.snapshot.actuals
        let travel = model.snapshot.travel
        let stays = model.snapshot.places
        let placeKinds = FrequentPlaceResolutionEngine().kindsByPlaceKey(
            model.snapshot.settings.frequentPlaces
        )
        let sealedDays = model.sealedDays
        var result = await Task.detached(priority: .utility) {
            MapHomeCalendarTimeTotalsPolicy.totals(
                actuals: actuals,
                travel: travel,
                stays: stays,
                placeKinds: placeKinds,
                month: month,
                asOf: .now,
                calendar: MapHomeGrowthPolicy.localCalendar,
                sealed: sealedDays
            )
        }.value
        // 걸음 수·사진 수는 사용자가 "+"로 켠 때만 읽는다(건강·사진 접근 비용을 아끼기 위해).
        let enabled = MapHomeCalendarTimeKind.enabledExtras(
            from: UserDefaults.standard.string(forKey: MapHomeCalendarTimeKind.extraStorageKey) ?? ""
        )
        if enabled.contains(.steps) || enabled.contains(.stepDistance) {
            let stride = MapHomeStride.current
            for (day, steps) in await model.calendarDailyStepCounts(month: month) {
                if enabled.contains(.steps) { result[day, default: [:]][MapHomeCalendarTimeKind.steps.rawValue] = steps }
                if enabled.contains(.stepDistance), steps > 0 {
                    result[day, default: [:]][MapHomeCalendarTimeKind.stepDistance.rawValue] = steps * stride
                }
            }
        }
        // 월 기록 목록이 비어 있으면(지도에는 보이는 날도) 날짜별 기록에서 다시 센다. 지도와 같은 출처를 쓴다.
        if result.isEmpty {
            result = await dayFallbackTotals(month: month)
        }
        if includePhotos, enabled.contains(.photos) {
            let library = photoLibrary
            let counts = await Task.detached(priority: .utility) {
                MapHomeCalendarTimeTotalsPolicy.photoCounts(in: month, moments: library.moments(in:), calendar: MapHomeGrowthPolicy.localCalendar)
            }.value
            for (day, count) in counts {
                result[day, default: [:]][MapHomeCalendarTimeKind.photos.rawValue] = count
            }
        }
        return result
    }

    /// 오늘 근무 시간(지금·1분 전)과, 필요하면 이번 달·지난달 합계를 다시 세어 연봉 카운터 값을 만든다.
    private func refreshSalary(includeMonth: Bool) async {
        let settings = MapHomeSalaryPolicy.loadSettings()
        guard settings.isConfigured else {
            if salaryLive != nil { salaryLive = nil }
            return
        }
        let actuals = model.snapshot.actuals
        let travel = model.snapshot.travel
        let stays = model.snapshot.places
        let placeKinds = FrequentPlaceResolutionEngine().kindsByPlaceKey(model.snapshot.settings.frequentPlaces)
        let calendar = MapHomeGrowthPolicy.localCalendar
        let now = Date.now
        let previous = salaryLive
        let selectedDay = calendar.startOfDay(for: model.selectedDate)
        // 확정한 지나간 날은 저장해 둔 값을 쓴다(달마다 수십 일을 다시 계산하지 않는다).
        let sealedDays = model.sealedDays
        let counted = await Task.detached(priority: .utility) { () -> (today: TimeInterval, minuteAgo: TimeInterval, month: [Date: [String: TimeInterval]]?, projected: TimeInterval?, pastMonths: [String: TimeInterval]?, selectedSpans: [TimeSpan], todaySpans: [TimeSpan]) in
            let dayStart = calendar.startOfDay(for: now)
            let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? now
            let span = TimeSpan(start: dayStart, end: dayEnd)
            func daySpans(_ day: Date) -> [TimeSpan] {
                let end = calendar.date(byAdding: .day, value: 1, to: day) ?? day
                return MapHomeSalaryPolicy.workSpans(
                    actuals: actuals, travel: travel, stays: stays, placeKinds: placeKinds,
                    day: TimeSpan(start: day, end: end), asOf: now
                )
            }
            func work(asOf date: Date) -> TimeInterval {
                MapHomeCalendarTimeTotalsPolicy.categorySeconds(
                    actuals: actuals, travel: travel, stays: stays, placeKinds: placeKinds, in: span, asOf: date
                )[MapHomeSalaryPolicy.workKey] ?? 0
            }
            guard includeMonth else { return (work(asOf: now), work(asOf: now - 60), nil, nil, nil, daySpans(selectedDay), daySpans(dayStart)) }
            func monthTotals(_ month: Date) -> [Date: [String: TimeInterval]] {
                MapHomeCalendarTimeTotalsPolicy.totals(
                    actuals: actuals, travel: travel, stays: stays, placeKinds: placeKinds,
                    month: month, asOf: now, calendar: calendar, sealed: sealedDays
                )
            }
            let thisMonth = monthTotals(now)
            // 추세는 최근 8주, 수당 모델은 지난 석 달의 (근무 시간, 받은 월급)을 쓴다.
            var dailyWork: [Date: TimeInterval] = [:]
            var pastMonths: [String: TimeInterval] = [:]
            for offset in 0...3 {
                let month = calendar.date(byAdding: .month, value: -offset, to: now) ?? now
                let totals = offset == 0 ? thisMonth : monthTotals(month)
                var monthWork: TimeInterval = 0
                for (day, values) in totals {
                    if let work = values[MapHomeSalaryPolicy.workKey], work > 0 { dailyWork[day] = work; monthWork += work }
                }
                if offset > 0 { pastMonths[MapHomeSalaryPolicy.monthKey(month, calendar: calendar)] = monthWork }
            }
            let projected = MapHomeSalaryPolicy.projectedMonthWorkSeconds(dailyWork: dailyWork, now: now, calendar: calendar)
            return (work(asOf: now), work(asOf: now - 60), thisMonth, projected, pastMonths, daySpans(selectedDay), daySpans(dayStart))
        }.value
        guard !Task.isCancelled else { return }
        let monthWork = counted.month.map { MapHomeSalaryPolicy.monthSummary(totals: $0, hourlyRate: 0).workSeconds }
            ?? previous?.month?.workSeconds ?? 0
        let projected = counted.projected ?? previous?.projectedMonthWorkSeconds ?? 0
        let pastMonths = counted.pastMonths ?? previous?.pastMonthWorkSeconds ?? [:]
        let samples = MapHomeSalaryPolicy.paySamples(settings, pastMonthWorkSeconds: pastMonths)
        guard let rate = MapHomeSalaryPolicy.hourlyRate(
            settings, monthWorkSeconds: monthWork, projectedMonthWorkSeconds: projected, samples: samples
        ) else { return }
        let expectedPay = MapHomeSalaryPolicy.expectedMonthPay(
            settings, projectedMonthWorkSeconds: max(projected, monthWork), samples: samples
        ) ?? MapHomeSalaryPolicy.displayedMonthly(settings)
        var month = counted.month.map { MapHomeSalaryPolicy.monthSummary(totals: $0, hourlyRate: rate) } ?? previous?.month
        // 이번 달 누적을 직접 고쳤으면 그 금액을 쓴다.
        if settings.monthAccumOverride > 0, let summary = month {
            month?.earnings = settings.monthAccumOverride
            let hours = (summary.workSeconds + summary.commuteSeconds) / 3_600
            month?.effectiveHourlyRate = summary.commuteSeconds > 0 && hours > 0 ? settings.monthAccumOverride / hours : nil
        }
        let live = MapHomeSalaryPolicy.Live(
            todayWorkSeconds: counted.today,
            measuredAt: now,
            isWorking: MapHomeSalaryPolicy.isWorking(workNow: counted.today, workMinuteAgo: counted.minuteAgo),
            hourlyRate: rate,
            month: month,
            showsNet: settings.showsNetAmounts,
            projectedMonthWorkSeconds: projected,
            expectedMonthPay: settings.monthAccumOverride > 0 ? settings.monthAccumOverride : expectedPay,
            pastMonthWorkSeconds: pastMonths
        )
        if live != salaryLive { salaryLive = live }
        // 선택한 날짜가 오늘이면 같은 키라 사전 리터럴로 만들면 중복 키로 멈춘다(오늘 값이 이긴다).
        var spans = [selectedDay: counted.selectedSpans]
        spans[calendar.startOfDay(for: now)] = counted.todaySpans
        if spans != salaryWorkSpans { salaryWorkSpans = spans }
    }

    /// 잠금 화면 활동 카드가 연봉을 실시간으로 올릴 수 있게 기준값(근무 초·시급·측정 시각)을 기기 설정에 적는다.
    private func persistSalaryForLockScreen() {
        SalaryLiveSnapshot.write(salaryLive.map { live in
            SalaryLiveSnapshot(
                text: MapHomeSalaryPolicy.wonText(MapHomeSalaryPolicy.earnings(
                    workSeconds: live.todayWorkSeconds, hourlyRate: live.hourlyRate)),
                baseSeconds: live.todayWorkSeconds, hourlyRate: live.hourlyRate,
                measuredAt: live.measuredAt, isWorking: live.isWorking, tickSeconds: salaryTickSeconds
            )
        })
    }

    /// 화랑이(집에 있으면 집 핀) 머리 위 카운터 창. 연봉과 나머지 카운터를 **한 상자**에 담는다.
    /// 업무 구간에서만 오르고, 재생 중에는 재생 시각까지 번 돈을 표시 간격 단위로 보여 준다.
    /// 창은 **스스로 박자**를 가진다 — 연봉 줄을 껐어도 나머지 숫자가 시간을 따라 움직인다.
    /// 재생·Apple 지도 이동 중에는 UIKit 뷰가 위치만 옮기고(PRF1101A01), 내용은 0.25초 박자로만 다시 만든다(PRF1101B01).
    private func counterWindow(
        at anchor: CGPoint,
        tracksPlaybackPoint: Bool = false,
        tracksAppleCamera: Bool = false
    ) -> some View {
        let box = counterWindowFrame
        let channel = tracksPlaybackPoint && playbackDriver != nil ? vectorMapViewportStore.liveChannel
            : tracksAppleCamera && isAppleCameraMoving ? appleStickmanLivePoint.channel
            : nil
        return MapHomeLivePointFollower(
            channel: channel,
            attachment: tracksAppleCamera ? appleStickmanLivePoint.markerAttachment : nil,
            fallback: CGPoint(x: anchor.x, y: anchor.y - 8 - 160),
            offset: CGSize(width: 0, height: MapHomeStickmanAnnotationLayout.centerOffset.y - 42 - 8 - 160),
            onFrame: { box.hostFrame = $0 }
        ) {
            EquatableView(content: MapHomeCounterContentGate(playbackTick: MapHomeCounterBadgeThrottle.playbackTick(isPlaying: isDayPlaybackRunning), isCollapsed: isCounterCollapsed) {
                if isCounterCollapsed {
                    MapHomeCounterFoldedIcon()
                        .onGeometryChange(for: CGSize.self, of: \.size) { box.contentSize = $0 }
                } else {
                    MapHomeCounterClock(isLive: isCounterLive) { now in
                        VStack(spacing: 2) {
                            counterWindowContent(now: now)
                            MapHomeCounterFoldArrow()
                        }
                        .onGeometryChange(for: CGSize.self, of: \.size) { box.contentSize = $0 }
                    }
                }
            })
            .frame(width: 240, height: 320, alignment: .bottom)
        }
        .onDisappear { box.reset() }
        .allowsHitTesting(false)
        .zIndex(MapHomeLayerPriority.stickman)
    }

    /// 오늘을 보고 있거나 재생 중이면 카운터 값이 흐른다. 지난 날은 값이 변하지 않는다.
    private var isCounterLive: Bool {
        isDayPlaybackRunning
            || MapHomeGrowthPolicy.localCalendar.isDateInToday(model.selectedDate)
    }

    /// 창에 넣을 값. `now`는 시계가 준 순간이라 연봉과 나머지 줄이 같은 박자로 갱신된다.
    @ViewBuilder
    private func counterWindowContent(now: Date) -> some View {
        if let salaryLive, showsSalaryCounter {
            let tick = TimeInterval(max(1, salaryTickSeconds))
            let calendar = MapHomeGrowthPolicy.localCalendar
            let day = calendar.startOfDay(for: model.selectedDate)
            if let minute = counterCutoffMinute {
                let seconds = MapHomeSalaryPolicy.workSeconds(in: salaryWorkSpans[day] ?? [], until: day + minute * 60)
                counterTable(now: now, salarySeconds: MapHomeSalaryPolicy.quantized(seconds, tick: tick), isWorking: false)
            } else if calendar.isDateInToday(model.selectedDate) {
                counterTable(
                    now: now,
                    salarySeconds: MapHomeSalaryPolicy.liveWorkSeconds(
                        base: salaryLive.todayWorkSeconds,
                        baseDate: salaryLive.measuredAt,
                        isWorking: salaryLive.isWorking,
                        now: now,
                        tick: tick
                    ),
                    isWorking: salaryLive.isWorking
                )
            } else {
                let seconds = MapHomeSalaryPolicy.workSeconds(in: salaryWorkSpans[day] ?? [], until: .distantFuture)
                counterTable(now: now, salarySeconds: seconds, isWorking: false)
            }
        } else {
            counterTable(now: now, salarySeconds: nil, isWorking: false)
        }
    }

    /// 창에 넣을 값. 연봉이 없으면 나머지 카운터만 담는다.
    private func counterTable(now: Date, salarySeconds: TimeInterval?, isWorking: Bool) -> some View {
        let salary = salarySeconds.flatMap { seconds in
            salaryLive.map { MapHomeCounterSalary.earned(seconds: seconds, hourlyRate: $0.hourlyRate, isWorking: isWorking, language: language) }
        }
        let allowance = !showsSalaryCounter ? nil : MapHomeAllowancePolicy.counterLine(
            day: model.selectedDate, playbackMinute: counterCutoffMinute,
            now: now, tick: TimeInterval(max(1, salaryTickSeconds)), language: language
        )
        let badges = mapCounterBadges(asOf: now)
        let targets = badges.map { MapHomeCounterDetailTarget.kind($0.kind) } + (allowance == nil ? [] : [.allowance]) + (salary == nil ? [] : [.salary])
        return MapHomeCounterTable(salary: salary, allowance: allowance, badges: badges, language: language)
            .onChange(of: targets, initial: true) { _, next in
                if counterRowTargets != next { counterRowTargets = next }
            }
    }

    private func salaryAnchor(viewport: MapHomeVectorViewport?, stickmanPoint: CGPoint?) -> CGPoint? {
        if let stickmanPoint {
            return CGPoint(x: stickmanPoint.x, y: stickmanPoint.y + MapHomeStickmanAnnotationLayout.centerOffset.y - 42)
        }
        guard let home = model.settings.frequentPlaces.first(where: { $0.kind == .home }),
              let pin = vectorPoint(in: viewport, for: vectorPlaceMarkerID(home.id)) else { return nil }
        // 화랑이가 집에 있으면 핀 안의 화랑이 바로 위, 아니면 집 지붕 위 날씨 배지 위에 둔다.
        return CGPoint(x: pin.x, y: pin.y + MapHomePlacePinLayout.salaryOffsetFromPinCenter)
    }

    /// 화랑이 위에 쌓아 보여 줄 카운터 값. 켠 것만, 값이 있는 것만 올린다.
    ///
    /// `now`는 창의 시계가 준 순간이다. 재생 중이면 재생 시각까지, 멈춰 있으면 지금까지로
    /// 잘라 센다. 이 값이 매번 새로 계산되더라도 분 버킷 캐시가 하루 전체 재계산을 막는다.
    private func mapCounterBadges(asOf now: Date) -> [MapHomeCounterBadge] {
        let probe = MapHomePlaybackProbe.begin("counterBadges"); defer { MapHomePlaybackProbe.end(probe) }
        let key = MapHomeCounterBadgeThrottle.Key(
            revision: model.dayProjectionRevision,
            day: model.selectedDate,
            kinds: enabledCounterKinds,
            english: language == .english,
            handleMinute: isDayPlaybackRunning ? nil : selectedTimelineMinute
        )
        return counterBadgeThrottle.badges(
            key: key,
            isPlaying: isDayPlaybackRunning,
            uptime: ProcessInfo.processInfo.systemUptime
        ) { computeMapCounterBadges(asOf: now) }
    }

    private func computeMapCounterBadges(asOf now: Date) -> [MapHomeCounterBadge] {
        let cutoff = counterCutoffDate
        let seconds = counterValueCache.categorySeconds(
            cutoff: cutoff,
            now: now,
            revision: model.dayProjectionRevision
        ) { daySummaryCategorySeconds(asOf: $0, now: now) }
        let steps = MapHomeCounterTimelinePolicy.stepCount(readings: currentDayReadings, cutoff: cutoff)
        let meters = MapHomeCounterTimelinePolicy.travelMeters(
            segments: displayDayDataSnapshot?.travel ?? [], cutoff: cutoff, day: selectedDaySpan)
        return enabledCounterKinds.compactMap { kind in
            counterText(kind, seconds: seconds, steps: steps, meters: meters, showsZero: cutoff != nil)
                .map { MapHomeCounterBadge(kind: kind, text: $0) }
        }
    }

    /// 재생 중이면 재생 시각, 아니면 사이드바 핸들 시각. 핸들을 놓아 둔 게 없으면 nil(하루 전체 합계).
    private var counterCutoffMinute: Double? {
        isDayPlaybackRunning ? dayPlaybackCurrentMinute : selectedTimelineMinute.map(Double.init)
    }

    private var counterCutoffDate: Date? {
        MapHomeCounterTimelinePolicy.cutoff(
            dayStart: MapHomeGrowthPolicy.localCalendar.startOfDay(for: model.selectedDate),
            minute: counterCutoffMinute
        )
    }

    private var selectedDaySpan: TimeSpan { MapHomeCounterTimelinePolicy.daySpan(of: model.selectedDate) }

    private func counterText(
        _ kind: MapHomeCounterKind,
        seconds categorySeconds: [String: TimeInterval],
        steps: Int?,
        meters: Double,
        showsZero: Bool
    ) -> String? {
        // 핸들·재생 시각을 움직이는 동안 0이라고 줄을 없애면 창이 들썩인다.
        switch kind {
        case .steps:
            guard showsZero || (steps ?? 0) > 0 else { return nil }
            return (steps ?? 0).formatted()
        case .distance:
            guard showsZero || meters > 0 else { return nil }
            return MapHomeDayTravelSummary.distanceText(meters)
        case .work, .study, .hobby, .exercise:
            // 켜 둔 시간 카운터는 위치와 상관없이 늘 보인다. 값이 없으면 0으로 보이고, 사라졌다 나타나지 않는다(대표 지시, ARC1030A07).
            guard let categoryID = kind.categoryID else { return nil }
            return DurationText.localized(max(0, categorySeconds[categoryID] ?? 0), english: language == .english)
        }
    }

    /// 날짜별 기록(지도가 쓰는 출처)으로 한 달 합계를 만든다. 오늘까지의 날짜만 본다.
    /// 저장된 기록 목록에 없는 날(최근 이틀처럼 지도에는 보이는 날)은 날짜별 기록에서 다시 판정해 달력 점을 채운다.
    /// 지도와 같은 출처를 쓰므로, 지도에는 기록이 있는데 달력 점만 비는 일이 없다(대표 지적 "달력 점 안나옴", ARC1030A03).
    private func calendarLogStatusesFillingGaps(
        _ base: [Date: MapHomeCalendarLogStatus], month: Date
    ) async -> [Date: MapHomeCalendarLogStatus] {
        let calendar = MapHomeGrowthPolicy.localCalendar
        guard let first = calendar.date(from: calendar.dateComponents([.year, .month], from: month)),
              let days = calendar.range(of: .day, in: .month, for: first) else { return base }
        var result = base
        var filled = 0
        for offset in 0..<days.count {
            guard let day = calendar.date(byAdding: .day, value: offset, to: first), day <= .now,
                  result[day] == nil,
                  let data = await model.cachedPlanDayDataSnapshot(for: day) else { continue }
            let statuses = MapHomeCalendarLogStatusPolicy.statuses(
                actuals: data.actuals, travel: data.travel, month: day, asOf: .now, calendar: calendar
            )
            if let status = statuses[day] { result[day] = status; filled += 1 }
        }
        if filled > 0 {
            TaptionPlanDiagnosticsLogger.shared.record("calendar_log_status_filled", metrics: ["filled": Double(filled)])
        }
        return result
    }

    private func dayFallbackTotals(month: Date) async -> [Date: [String: TimeInterval]] {
        let calendar = MapHomeGrowthPolicy.localCalendar
        guard let first = calendar.date(from: calendar.dateComponents([.year, .month], from: month)),
              let days = calendar.range(of: .day, in: .month, for: first) else { return [:] }
        let placeKinds = FrequentPlaceResolutionEngine().kindsByPlaceKey(model.snapshot.settings.frequentPlaces)
        var result: [Date: [String: TimeInterval]] = [:]
        var loaded = 0, missing = 0, withRecords = 0
        for offset in 0..<days.count {
            guard let day = calendar.date(byAdding: .day, value: offset, to: first), day <= .now else { continue }
            guard let data = await model.cachedPlanDayDataSnapshot(for: day) else { missing += 1; continue }
            loaded += 1
            let totals = MapHomeCalendarTimeTotalsPolicy.totals(
                actuals: data.actuals, travel: data.travel, stays: data.places,
                placeKinds: placeKinds, month: day, asOf: .now, calendar: calendar
            )
            if let values = totals[day] { result[day] = values; withRecords += 1 }
        }
        TaptionPlanDiagnosticsLogger.shared.record(
            "calendar_day_fallback",
            metrics: ["loaded": Double(loaded), "missing": Double(missing), "with_records": Double(withRecords)]
        )
        return result
    }

    /// 녹화 메뉴를 열기 전에 사진 저장 권한과 화면 기록 허용을 먼저 받는다.
    private func openRecordingOptions() {
        Task { @MainActor in
            guard await MapHomeScreenRecordingStore.requestPhotoAddAccess() else {
                recordingFailureMessage = "사진 저장 권한이 없어 녹화하지 않았습니다. 설정에서 사진 권한을 허용해 주세요."
                return
            }
            guard await screenRecorder.probePermission() else {
                recordingFailureMessage = screenRecorder.lastFailureMessage ?? "화면 녹화를 시작하지 못했습니다."
                return
            }
            isRecordingOptionsPresented = true
        }
    }

    private func startRecordingPlayback() {
        isRecordingOptionsPresented = false
        // 권한 확인·ReplayKit 시작 대기 동안 기존 재생이 계속 돌지 않게 먼저 멈춘다.
        if isDayPlaybackRunning { stopDayPlayback(resetProgress: true) }
        Task { @MainActor in
            // 권한은 재생 전에 먼저 묻는다: 사진 저장 → 화면 녹화.
            guard await MapHomeScreenRecordingStore.requestPhotoAddAccess() else {
                TaptionPlanDiagnosticsLogger.shared.record("screen_recording_blocked", fields: ["reason": "photo_access_denied"])
                recordingFailureMessage = "사진 저장 권한이 없어 녹화하지 않았습니다. 설정에서 사진 권한을 허용해 주세요."
                return
            }
            isScreenRecording = true
            // 시트가 내려가고 화면이 정리될 시간을 둔다.
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard await screenRecorder.start() else {
                isScreenRecording = false
                recordingFailureMessage = screenRecorder.lastFailureMessage ?? "화면 녹화를 시작하지 못했습니다."
                return
            }
            // 녹화는 항상 자정(0시)부터 처음부터 재생한다.
            startDayPlayback(fromMidnight: true)
        }
    }

    private func finishRecordingPlayback() {
        guard isScreenRecording else { return }
        Task { @MainActor in
            let url = await screenRecorder.stop()
            isScreenRecording = false
            guard let url else { return }
            let saved = await MapHomeScreenRecordingStore.saveToPhotos(url)
            TaptionPlanDiagnosticsLogger.shared.record("screen_recording_saved", fields: ["saved": saved ? "true" : "false"])
            // 녹화 화면을 닫는 애니메이션이 끝난 뒤 공유 시트를 연다.
            try? await Task.sleep(for: .milliseconds(400))
            recordedVideoShare = url
        }
    }

    private func toggleDayPlayback() {
        if isDayPlaybackRunning {
            stopDayPlayback(resetProgress: false)
        } else {
            startDayPlayback()
        }
    }

    /// 재생은 사이드바 시각과 상관없이 늘 자정(00시)부터 시작한다(대표 지시, ARC1030A02).
    private func startDayPlayback(fromMidnight: Bool = true) {
        dayPlaybackTask?.cancel()
        let currentDate = Date.now
        let playbackEndMinute = MapHomeDayPlaybackMath.playbackEndMinute(
            for: model.selectedDate,
            now: currentDate
        )
        let defaultMinute = MapHomeDayPlaybackMath.playbackStartMinute(
            selectedMinute: selectedTimelineMinute,
            endMinute: playbackEndMinute,
            isToday: Calendar.autoupdatingCurrent.isDate(
                model.selectedDate,
                inSameDayAs: currentDate
            )
        )
        let pawSelection = MapHomePawprintInteractionPolicy.selection(
            timestamp: selectedPawprintTimestamp, isPredicted: false,
            selectedDate: model.selectedDate
        )
        let currentMinute = fromMidnight ? 0 : (pawSelection.map {
            defaultMinute == Double($0.minute) && $0.minuteOffset < playbackEndMinute
                ? $0.minuteOffset : defaultMinute
        } ?? defaultMinute)
        selectedPawprintTimestamp = nil
        selectedPawprintCoordinate = nil
        var playbackMinute = currentMinute
        dayPlaybackCurrentMinute = currentMinute
        let movingRanges = dayPlaybackMovementRanges
        playbackZoomPlan = makePlaybackZoomPlan(movingRanges: movingRanges)
        if currentMinute == 0 {
            selectedTimelineMinute = 0
        }
        isTimelineSelectionPinned = true
        isTimelineInteractionActive = true
        isDayPlaybackRunning = true
        playbackZoomSmoother.reset()
        lastPlaybackRouteProjectionUptime = 0
        lastPlaybackMapFocusUptime = 0
        lastPlaybackMarkerUptime = 0
        mapRenderCache.invalidateRouteData()
        routeProjection = nil
        timelineRouteOverlays = []
        prepareRouteProjectionReadings()
        hasDeferredWBSPlaybackRefresh = false
        refreshWBSPlaybackProjection()
        refreshRouteProjection()
        recordCurrentPlaybackAlignment()
        lastPlaybackRouteProjectionUptime = ProcessInfo.processInfo.systemUptime
        // 재생은 개요 연출 없이 00시 위치로 바로 포커싱한다(대표 지시, ARC1030A05).
        isPlaybackIntroActive = false
        playbackIntroTask?.cancel()
        // 벡터 지도와 Apple 지도 모두 구동기가 프레임마다 지도 엔진에 카메라를 바로 놓는다(대표 지시, ARC1030A04).
        startDriverPlayback(
            startMinute: currentMinute, endMinute: playbackEndMinute, movingRanges: movingRanges
        )
    }

    private var dayPlaybackMovementRanges: [MapHomePlaybackMovementRange] {
        let calendar = Calendar.autoupdatingCurrent
        let dayData = currentDayDataSnapshot
        let dayStart = calendar.startOfDay(for: model.selectedDate)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(24 * 60 * 60)
        let readingRanges = dayPlaybackReadingRanges(
            from: routeReadings + model.liveRouteState.readings,
            dayStart: dayStart,
            dayEnd: dayEnd
        )
        // 세부 활동(머무름·휴식·걷기)을 이동 구간에서 떼어 각자의 속도로 재생한다.
        let details: [(start: Double, end: Double, mode: TravelMode?, isStationary: Bool)] = (dayData?.actuals ?? []).compactMap { actual in
            let start = actual.startedAt.timeIntervalSince(dayStart) / 60
            let end = (actual.endedAt ?? actual.startedAt.addingTimeInterval(60)).timeIntervalSince(dayStart) / 60
            guard end > start else { return nil }
            let title = actual.title
            if title.contains("걷기") || title.contains("Walk") {
                return (start, end, .walking, false)
            }
            if title.contains("머무름") || title.contains("휴식") || title.contains("Rest") || title.contains("Stay") {
                return (start, end, nil, true)
            }
            return nil
        }
        let travelRanges = (dayData?.travel ?? []).flatMap { segment -> [MapHomePlaybackMovementRange] in
            // 확정되지 않은 이동도 대분류가 '이동'이면 이동 배속으로 지나간다(정지 배속이면 한순간에 사라진다).
            guard segment.distanceMeters > 0
                    || segment.mode == .subway
                        && ((segment.subwayRoute?.coordinates.count ?? 0) >= 2)
            else { return [] }
            let range = MapHomePlaybackMovementRange(
                startMinute: segment.span.start.timeIntervalSince(dayStart) / 60,
                endMinute: segment.span.end.timeIntervalSince(dayStart) / 60,
                mode: segment.mode
            )
            return MapHomePlaybackMovementRange.carved(range, details: details)
        }
        // 이동으로 분류된 시간은 확정 여부·센서 유무와 상관없이 이동 배속으로 본다.
        let categoryRanges = MapHomePlaybackCategoryRanges.movementRanges(
            snapshot: dayData, frequentPlaces: model.snapshot.settings.frequentPlaces,
            dayStart: dayStart, dayEnd: dayEnd)
        return MapHomePlaybackCategoryRanges.removingSleep(MapHomePlaybackMovementRange.normalized(
            readingRanges + travelRanges + categoryRanges
        ), snapshot: dayData, dayStart: dayStart)
    }

    private func dayPlaybackReadingRanges(
        from readings: [SensorReading],
        dayStart: Date,
        dayEnd: Date
    ) -> [MapHomePlaybackMovementRange] {
        let ordered = readings
            .filter {
                RouteTimelineTimestamp.isValid($0.timestamp)
                    && $0.timestamp >= dayStart
                    && $0.timestamp < dayEnd
                    && $0.point != nil
                    && $0.motion.isMovement
            }
            .sorted { $0.timestamp < $1.timestamp }
        guard let first = ordered.first else { return [] }

        var result: [MapHomePlaybackMovementRange] = []
        var start = first.timestamp
        var previous = first.timestamp
        var mode = playbackMode(for: first)
        for reading in ordered.dropFirst() {
            let nextMode = playbackMode(for: reading)
            if reading.timestamp.timeIntervalSince(previous) > 15 * 60
                || nextMode != mode {
                result.append(
                    MapHomePlaybackMovementRange(
                        startMinute: start.timeIntervalSince(dayStart) / 60,
                        endMinute: previous.timeIntervalSince(dayStart) / 60,
                        mode: mode
                    )
                )
                start = reading.timestamp
                mode = nextMode
            }
            previous = reading.timestamp
        }
        result.append(
            MapHomePlaybackMovementRange(
                startMinute: start.timeIntervalSince(dayStart) / 60,
                endMinute: previous.timeIntervalSince(dayStart) / 60,
                mode: mode
            )
        )
        return result
    }

    private func playbackMode(for reading: SensorReading) -> TravelMode? {
        if reading.matchesRailRoute
            || (reading.subwayWiFiObservationStreak ?? 0) > 0 {
            return .subway
        }
        if reading.matchesPublicTransitRoute {
            return .bus
        }
        if reading.onWater {
            return .ship
        }
        switch reading.motion {
        case .walking: return .walking
        case .running: return .running
        case .cycling: return .cycling
        case .automotive: return .car
        case .stationary, .unknown: return nil
        }
    }

    /// 재생 중이면 **취소**한다. 재생을 시작하기 전 시각으로 되돌리므로
    /// (`resetProgress: true`) '멈춤'이 아니라 '취소'다. 지도를 움직이거나
    /// 현재 위치로 갈 때 부른다 — 하단 단추는 늘리지 않는다(대표 요청, 2026-10-26).
    private func cancelDayPlaybackIfRunning() {
        guard isDayPlaybackRunning else { return }
        stopDayPlayback(resetProgress: true)
    }

    /// 재생 구동기를 세운다. 프레임 계산은 구동기, 화면 갱신은 정수 분마다(PLY1029A03).
    private func makePlaybackZoomPlan(movingRanges: [MapHomePlaybackMovementRange]) -> MapHomePlaybackZoomPlan {
        let dayStart = Calendar.autoupdatingCurrent.startOfDay(for: model.selectedDate)
        let readings = routeReadings + model.liveRouteState.readings
        let places = model.settings.frequentPlaces.compactMap(\.point)
        return MapHomePlaybackZoomPlan(
            inputs: MapHomePlaybackZoomInputBuilder.inputs(
                ranges: movingRanges, dayStart: dayStart, travel: currentDayDataSnapshot?.travel ?? [],
                readings: readings, places: places
            ),
            profile: MapHomePlaybackZoomProfile.build(readings: readings, places: places, dayStart: dayStart)
        )
    }

    /// 실시간 재생과 영상 렌더링이 같은 입력을 쓴다(VID1029A01).
    private func playbackDriverInputs(
        startMinute: Double, endMinute: Double, movingRanges: [MapHomePlaybackMovementRange],
        zoomPlan: MapHomePlaybackZoomPlan
    ) -> MapHomePlaybackDriver.Inputs {
        .init(
            startMinute: startMinute, endMinute: endMinute, movingRanges: movingRanges,
            dayStart: Calendar.autoupdatingCurrent.startOfDay(for: model.selectedDate),
            readings: routeReadingsLoadState.isLoaded(for: model.selectedDate) ? historicalPlaybackReadings : [],
            travel: currentDayDataSnapshot?.travel ?? [],
            places: currentDayDataSnapshot?.places ?? [],
            zoomPlan: zoomPlan
        )
    }

    /// 하루 재생을 프레임마다 그려 끊김 없는 60fps 영상으로 만든다(VID1029A01). 화랑이는 정중앙 고정.
    private func makePlaybackVideoRenderer() -> MapHomePlaybackVideoRenderer? {
        guard let style = model.settings.mapDisplayStyle.runtimeStyle.mapHomeVectorStyle else { return nil }
        let ranges = dayPlaybackMovementRanges
        let end = MapHomeDayPlaybackMath.playbackEndMinute(for: model.selectedDate, now: .now)
        var timeline = MapHomePlaybackTimeline(
            inputs: playbackDriverInputs(
                startMinute: 0, endMinute: end, movingRanges: ranges, zoomPlan: makePlaybackZoomPlan(movingRanges: ranges)
            ),
            projection: wbsPlaybackProjection
        )
        timeline.preferredForecastLegIDs = visibleForecastPlaybackLegIDs
        timeline.expectedCoordinate = expectedRouteCoordinateLookup()
        timeline.isAdaptiveZoom = MapHomePlaybackZoomMode(rawValue: playbackZoomModeRaw) != .fixed
        let day = currentDayDataSnapshot
        let dayStart = Calendar.autoupdatingCurrent.startOfDay(for: model.selectedDate)
        let frequentPlaces = model.settings.frequentPlaces
        let sleepSessions = model.sleepSessions
        let accessory = homeGrowthHistory.season.equippedAccessory
        return MapHomePlaybackVideoRenderer(style: style, timeline: timeline) { minute in
            MapHomePlaybackVideoStickman(
                action: MapHomeStickmanActionResolver.action(
                    at: dayStart.addingTimeInterval(minute * 60), actuals: day?.actuals ?? [],
                    travel: day?.travel ?? [], places: day?.places ?? [], frequentPlaces: frequentPlaces,
                    sleepSessions: sleepSessions
                ),
                equippedAccessoryID: accessory
            )
        }
    }

    private func startDriverPlayback(
        startMinute: Double, endMinute: Double, movingRanges: [MapHomePlaybackMovementRange]
    ) {
        let driver = MapHomePlaybackDriver(inputs: playbackDriverInputs(
            startMinute: startMinute, endMinute: endMinute, movingRanges: movingRanges, zoomPlan: playbackZoomPlan
        ))
        syncPlaybackDriverProjection(driver)
        driver.isAdaptiveZoom = MapHomePlaybackZoomMode(rawValue: playbackZoomModeRaw) != .fixed
        driver.isCameraSuppressed = { isPlaybackIntroActive }
        // 측정용: `-benchMinute=none|sel|cur|proj`면 분 알림이 하는 일을 골라서 한다(정지 원인을 가를 때만 쓴다, ARC1030A01).
        let benchMinute = ProcessInfo.processInfo.arguments.first { $0.hasPrefix("-benchMinute=") }?
            .dropFirst("-benchMinute=".count)
        driver.onMinute = { minute in
            let probe = MapHomePlaybackProbe.begin("onMinute"); defer { MapHomePlaybackProbe.end(probe) }
            let whole = min(MapHomeTimeSidebarMath.fullDayMinutes, max(0, Int(minute.rounded(.down))))
            if benchMinute == nil || benchMinute == "sel" {
                if selectedTimelineMinute != whole { selectedTimelineMinute = whole }
            }
            if benchMinute == nil || benchMinute == "cur" {
                dayPlaybackCurrentMinute = Double(whole)
            }
            playbackProgress.advanceCoarseTickIfNeeded(nowUptime: ProcessInfo.processInfo.systemUptime)
            if TimelineInteractionFrameGate.shouldRender(
                lastUptime: &lastPlaybackTraceUptime,
                nowUptime: ProcessInfo.processInfo.systemUptime,
                minimumInterval: 5
            ) {
                // 재생 중 경로가 실제로 쌓이는지 로그로 남긴다(발자국이 안 나오던 문제 확인용, ARC1030A02).
                TaptionPlanDiagnosticsLogger.shared.record("playback_route_trace", fields: [:], metrics: [
                    "minute": minute,
                    "overlays": Double(timelineRouteOverlays.count),
                    "overlay_points": Double(timelineRouteOverlays.reduce(0) { $0 + $1.coordinates.count }),
                    "live_markers": Double(vectorMapViewportStore.livePlaybackViewport?.markerPoints.count ?? 0),
                    "in_flight": routeProjectionInFlight ? 1 : 0,
                    "runs": Double(routeProjectionRunID),
                    "applied": Double(routeProjectionApplied),
                    "last_ms": routeProjectionLastMS,
                    "segments": Double(routeProjection?.segments.count ?? -1),
                    "skip_nosnapshot": Double(routeProjectionSkips[0]),
                    "scene_active": scenePhase == .active ? 1 : 0,
                    "has_snapshot": dayDataSnapshot != nil ? 1 : 0,
                    "snapshot_complete": dayDataSnapshot?.isComplete == true ? 1 : 0,
                    "snapshot_version": Double(dayDataSnapshot?.projectionVersion ?? 0),
                    "same_day": dayDataSnapshot.map { Calendar.autoupdatingCurrent.isDate($0.day, inSameDayAs: model.selectedDate) ? 1.0 : 0.0 } ?? -1,
                    "rev_model": Double(model.dayProjectionRevision),
                    "rev_snapshot": Double(dayDataSnapshot?.sourceRevision ?? 0),
                    "skip_samekey": Double(routeProjectionSkips[1]),
                    "skip_inflight": Double(routeProjectionSkips[2]),
                ])
            }
            // 경로 투영은 지도 경로 전체를 다시 그린다. 재생 중에는 1초에 한 번만(PLY1029A06).
            if benchMinute == nil || benchMinute == "proj", TimelineInteractionFrameGate.shouldRender(
                lastUptime: &lastPlaybackRouteProjectionUptime,
                nowUptime: ProcessInfo.processInfo.systemUptime,
                minimumInterval: 1
            ) {
                refreshRouteProjection()
            }
        }
        driver.onFinished = { finishDayPlayback(endMinute: endMinute) }
        vectorMapViewportStore.livePlaybackViewport = nil
        playbackDriver = driver
        driver.start()
    }

    /// 예상 경로가 풀려 투영이 바뀌면 구동기에도 넘긴다.
    private func syncPlaybackDriverProjection(_ driver: MapHomePlaybackDriver? = nil) {
        guard let driver = driver ?? playbackDriver else { return }
        driver.projection = wbsPlaybackProjection
        driver.preferredForecastLegIDs = visibleForecastPlaybackLegIDs
        driver.expectedCoordinate = expectedRouteCoordinateLookup()
    }

    /// 화면에 그려진 예상 경로 위의 좌표를 시각으로 찾는다(구동기·영상 공용).
    private func expectedRouteCoordinateLookup() -> (Date) -> GeoPoint? {
        let overlays = expectedRouteOverlays
        let visibleIDs = Set(displayedExpectedRouteOverlays.map(\.id))
        return { date in
            let route = overlays.filter {
                visibleIDs.contains($0.id) && $0.coordinates.count >= 2
                    && $0.departureDate <= date && date <= $0.arrivalDate
            }.min { $0.departureDate < $1.departureDate }
            guard let coordinate = route?.coordinate(at: date), CLLocationCoordinate2DIsValid(coordinate) else { return nil }
            return wbsGeoPoint(coordinate)
        }
    }

    /// 재생이 끝까지 간 뒤의 마무리(예전 루프와 구동기가 함께 쓴다).
    private func finishDayPlayback(endMinute: Double) {
        selectedTimelineMinute = endMinute >= Double(MapHomeTimeSidebarMath.fullDayMinutes)
            ? MapHomeTimeSidebarMath.fullDayMinutes
            : min(MapHomeTimeSidebarMath.fullDayMinutes - 1, max(0, Int(endMinute.rounded(.down))))
        isDayPlaybackRunning = false
        isTimelineInteractionActive = false
        dayPlaybackCurrentMinute = nil
        _ = flushDeferredRouteProjection() ?? refreshRouteProjection()
        flushDeferredWBSPlaybackProjection()
        recordCurrentPlaybackAlignment()
        dayPlaybackTask = nil
        playbackDriver = nil
        lastPlaybackRouteProjectionUptime = 0
        lastPlaybackMapFocusUptime = 0
        lastPlaybackMarkerUptime = 0
    }

    private func stopDayPlayback(resetProgress: Bool) {
        playbackDriver?.stop()
        playbackDriver = nil
        playbackIntroTask?.cancel()
        isPlaybackIntroActive = false
        selectedPawprintTimestamp = nil
        selectedPawprintCoordinate = nil
        let wasRunning = isDayPlaybackRunning
        if wasRunning, !resetProgress, let currentMinute = dayPlaybackCurrentMinute {
            selectedTimelineMinute = min(
                MapHomeTimeSidebarMath.fullDayMinutes,
                max(0, Int(currentMinute.rounded(.down)))
            )
        }
        dayPlaybackTask?.cancel()
        dayPlaybackTask = nil
        isDayPlaybackRunning = false
        dayPlaybackCurrentMinute = nil
        lastPlaybackRouteProjectionUptime = 0
        lastPlaybackMapFocusUptime = 0
        lastPlaybackMarkerUptime = 0
        lastTimelineMapFocusUptime = 0
        if wasRunning {
            isTimelineInteractionActive = false
            _ = flushDeferredRouteProjection()
                ?? refreshRouteProjection()
            flushDeferredWBSPlaybackProjection()
            recordCurrentPlaybackAlignment()
        }
    }

    @ViewBuilder
    private var mapSideRails: some View {
        if !isMenuOpen || isWideLayout {
            GeometryReader { proxy in
                mapSideRailsContent(viewportSize: proxy.size)
            }
            .zIndex(MapHomeLayerPriority.sidebar)
        }
    }

    private func mapSideRailsContent(viewportSize: CGSize) -> some View {
        let frame = MapHomeOverlayLayoutMath.alignedRailFrame(
            viewportHeight: viewportSize.height,
            topInset: topOverlayHeight + Layout.timeRailTopMargin,
            bottomInset: Layout.horizontalInset + layoutStyle.bottomReservedHeight
        )
        let timeSidebarFrame = MapHomeOverlayLayoutMath.timeSidebarFrame(
            viewportHeight: viewportSize.height,
            topOverlayHeight: 0,
            topMargin: Layout.horizontalInset * 2 + Layout.dateBadgeSize,
            bottomMargin: Layout.horizontalInset + MapHomeWideLayoutPolicy.sidebarBottomReserve(viewportWidth: viewportSize.width, actionBarHeight: layoutStyle.bottomReservedHeight)
        )
        let timeSidebarWidth = MapHomeTimeSidebarMath.interactionWidth(
            railWidth: timeRailWidth,
            trailingInteractionWidth: Layout.horizontalInset
        )
        return HStack(alignment: .top, spacing: 0) {
            if !isScreenRecording, !Self.benchHidden("controls") {
            coarseRegion { mapControls(proxy: nil, railHeight: frame.height) }
                .onGeometryChange(
                    for: CGRect.self,
                    of: { geometry in
                        geometry.frame(in: .named("mapHomeViewport"))
                    },
                    action: { frame in
                        guard mapControlsFrame != frame else { return }
                        mapControlsFrame = frame
                    }
                )
            }
            Spacer(minLength: 0)
            Color.clear
                .frame(width: timeSidebarWidth, height: frame.height)
        }
        .padding(.leading, Layout.horizontalInset)
        .frame(maxWidth: .infinity)
        .frame(height: frame.height)
        .overlay(alignment: .topTrailing) {
            if isSidebarVisible {
                currentTimeRail
                    .frame(width: timeSidebarWidth, height: timeSidebarFrame.height)
                    .offset(y: timeSidebarFrame.minY - frame.minY)
                    .transition(.sidebarDrop)
            }
        }
        .position(x: viewportSize.width / 2, y: frame.midY)
    }

    private var currentTimeRail: some View {
        GeometryReader { proxy in
            // 확대·축소 단추가 들어갈 바닥 자리. 시간선·날씨 띠를 이만큼 줄여 아래를 비운다.
            let zoomReserve = min(32, proxy.size.height / 3)
            let railHeight = MapHomeOverlayLayoutMath.timeSidebarHeight(
                availableHeight: proxy.size.height - zoomReserve
            )
            TimelineView(.periodic(from: .now, by: 60)) { timeline in
                let minute = timelineSelectionMinute(at: timeline.date)
                let timeSidebarInteractionWidth =
                    MapHomeTimeSidebarMath.interactionWidth(
                        railWidth: timeRailWidth,
                        trailingInteractionWidth: Layout.horizontalInset
                    )
                let weatherOriginX = MapHomeWeatherRailAlignmentMath.weatherOriginX(
                    weatherRailWidth: Layout.weatherRailWidth,
                    timeRailWidth: timeRailWidth
                )
                let selectedTimeCard = MapHomeTimeSidebarMath.selectedTimeCardFrame(
                    availableHeight: railHeight,
                    selectedMinute: minute,
                    visibleStartMinute: timeSidebarVisibleStartMinute,
                    visibleDurationMinutes: timeSidebarVisibleDurationMinutes
                )
                let selectedCardHeight = min(railHeight, selectedTimeCard.height)
                let selectedCardCenterY = min(
                    max(selectedTimeCard.midY, selectedCardHeight / 2),
                    railHeight - selectedCardHeight / 2
                )
                let timeRailTop = max(0, proxy.size.height - zoomReserve - railHeight)
                ZStack(alignment: .topLeading) {
                    if recordingShows(\.timeSidebar) {
                    Capsule()
                        .fill(Color.tpAccent.opacity(0.07))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Color.tpAccent.opacity(0.20), lineWidth: 0.8)
                        }
                        .frame(
                            width: timeRailWidth - 12,
                            height: selectedCardHeight
                        )
                        .position(
                            x: proxy.size.width
                                - Layout.horizontalInset
                                - (timeRailWidth - 12) / 2,
                            y: timeRailTop + selectedCardCenterY
                        )
                        .allowsHitTesting(false)
                    }
                    if model.settings.weatherSidebarVisible, recordingShows(\.weatherSidebar), !Self.benchHidden("weather") {
                        let railWeather = displayWeatherContexts
                        if let notice = MapHomeWeatherNoticePolicy.notice(
                            status: model.weatherStatus,
                            hasDisplayableWeather: railWeather.contains {
                                MapHomeWeatherDisplayPolicy.isComplete($0)
                                    && Calendar.autoupdatingCurrent.isDate(
                                        $0.observedAt,
                                        inSameDayAs: model.selectedDate
                                    )
                            }
                        ) {
                            MapHomeWeatherNoticeView(notice: notice, language: language)
                                .frame(width: MapHomeWeatherNoticeView.width, alignment: .trailing)
                                .offset(
                                    x: weatherOriginX + Layout.weatherRailWidth
                                        - MapHomeWeatherNoticeView.width,
                                    y: 6
                                )
                                .allowsHitTesting(false)
                        }
                        coarseRegion {
                            MapHomeWeatherSidebar(
                                date: model.selectedDate,
                                contexts: railWeather,
                                selectedMinute: timelineSelectionMinute(at: timeline.date),
                                language: language,
                                visibleStartMinute: timeSidebarVisibleStartMinute,
                                visibleDurationMinutes: timeSidebarVisibleDurationMinutes
                            )
                        }
                        .offset(x: weatherOriginX)
                        .allowsHitTesting(false)
                    }
                    if recordingShows(\.timeSidebar), !Self.benchHidden("timebar") {
                    MapHomeTimeSidebar(
                        smoothsPlayback: isDayPlaybackRunning && playbackDriver != nil,
                        date: model.selectedDate,
                        selectedMinute: Binding(
                            get: { timelineSelectionMinute(at: timeline.date) },
                            set: { minute in
                                selectedPawprintTimestamp = nil
                                guard selectedTimelineMinute != minute else { return }
                                stopDayPlayback(resetProgress: true)
                                isTimelineSelectionPinned = true
                                selectedTimelineMinute = minute
                            }
                        ),
                        visibleStartMinute: $timeSidebarVisibleStartMinute,
                        visibleDurationMinutes: $timeSidebarVisibleDurationMinutes,
                        activity: model.isBootstrapped
                            ? currentActivity(at: minute)
                            : nil,
                        segments: timeRailSegments,
                        categoryColors: model.settings.mapCategoryColors,
                        zoomResetToken: zoomResetToken,
                        zoomStepToken: zoomStepToken,
                        railWidth: timeRailWidth,
                        maximumSelectableMinute: nil,
                        trailingInteractionWidth: Layout.horizontalInset,
                        onInteractionChanged: { isInteracting in
                            if isInteracting, isDayPlaybackRunning {
                                stopDayPlayback(resetProgress: true)
                            }
                            isTimelineInteractionActive = isInteracting
                            if isInteracting {
                                MapHomeInteractionMonitor.shared.begin("sidebar_drag", idleTimeout: 8)
                            } else {
                                MapHomeInteractionMonitor.shared.end("sidebar_drag")
                            }
                            if !isInteracting {
                                flushDeferredWBSPlaybackProjection()
                                recordTimelineWindow("handle_end")
                            }
                        },
                        onSectionEdit: { selectedMinute in
                            guard model.isBootstrapped else { return }
                            openSectionEditor(at: selectedMinute)
                        },
                        onCollapse: {
                            withAnimation(MapHomeView.sidebarToggleSpring) { isSidebarVisible = false }
                        },
                        onUnconfirmedReview: { segment in
                            guard model.isBootstrapped else { return }
                            focusedUnconfirmedReviewSegment = segment
                            isUnconfirmedReviewPresented = true
                        },
                        unconfirmedMode: { MapHomePlaybackLocation.gapMode(at: timelineDate(forMinute: Double($0.startMinute + $0.endMinute) / 2), travel: currentDayDataSnapshot?.travel ?? [], readings: historicalPlaybackReadings) }
                    )
                    // 확대·축소는 시간선 아래 비워 둔 자리에 사이드바와 같은 폭·모서리의 알약으로 눕힌다.
                    timelineZoomControls
                        .position(
                            x: proxy.size.width - Layout.horizontalInset - timeRailWidth / 2,
                            y: proxy.size.height - 11
                        )
                    }

                    ForEach(recordingShows(\.sidebarMemos) ? scheduleStickersForSelectedDate : []) { sticker in
                        let window = MapHomeTimeSidebarMath.visibleWindow(
                            startMinute: timeSidebarVisibleStartMinute,
                            durationMinutes: timeSidebarVisibleDurationMinutes,
                            centerMinute: effectiveTimelineMinute
                        )
                        let minute = minuteOfDay(for: sticker.occurredAt)
                        let trackHeight = max(
                            1,
                            railHeight - MapHomeTimeSidebarMath.verticalInset * 2
                        )
                        let y = MapHomeTimeSidebarMath.verticalInset
                            + trackHeight * MapHomeTimeSidebarMath.position(
                                minute: minute,
                                window: window
                            )
                        Button {
                            if isStickerMode { selectedMapStickerEditor = .sticker(sticker.id); return }
                            toggleSidebarNote(.sticker(sticker, minute: minute, badgeOffset: scheduleBadgeOffset(minute: minute, isEvent: false)))
                        } label: {
                            Image(systemName: sticker.systemImage)
                                .font(.system(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .bold))
                                .foregroundStyle(Color(hex: sticker.colorHex))
                                .frame(width: 22, height: 22)
                                .background(Color.white.opacity(0.96), in: Circle())
                                .overlay(Circle().stroke(Color(hex: sticker.colorHex), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(
                            language.text(
                                "\(sticker.title) 일정 메모",
                                "\(sticker.title) schedule memo"
                            )
                        )
                        // 날씨 칩의 왼쪽 끝에 맞춘다(캡처로 잰 값: 칩 왼쪽 끝 x 17, 스티커 반지름 11).
                        .position(
                            x: scheduleBadgeBaseX + scheduleBadgeOffset(minute: minute, isEvent: false),
                            y: min(
                                max(y, MapHomeTimeSidebarMath.verticalInset),
                                railHeight - MapHomeTimeSidebarMath.verticalInset
                            )
                        )
                    }

                    // 일정은 시작 시간에 구글 로고로 표시한다(스티커와 같은 열).
                    // 시간이 있는 메모는 메모 아이콘으로 사이드바 시간에 바로 보인다.
                    ForEach(recordingShows(\.sidebarMemos) ? timedMemosForSelectedDate : []) { memo in
                        let window = MapHomeTimeSidebarMath.visibleWindow(
                            startMinute: timeSidebarVisibleStartMinute,
                            durationMinutes: timeSidebarVisibleDurationMinutes,
                            centerMinute: effectiveTimelineMinute
                        )
                        let minute = minuteOfDay(for: memo.occurredAt)
                        let trackHeight = max(1, railHeight - MapHomeTimeSidebarMath.verticalInset * 2)
                        let y = MapHomeTimeSidebarMath.verticalInset
                            + trackHeight * MapHomeTimeSidebarMath.position(minute: minute, window: window)
                        Button {
                            toggleSidebarNote(.memo(memo, minute: minute, badgeOffset: scheduleBadgeOffset(minute: minute, isEvent: false)))
                        } label: {
                            Image(systemName: memo.stickerSymbol ?? "note.text")
                                .font(.system(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .bold))
                                .foregroundStyle(memo.isSticker ? Color(hex: memo.stickerColorHex ?? "#F28FA9") : Color.tpInk)
                                .frame(width: 22, height: 22)
                                .background(Color.white.opacity(0.96), in: Circle())
                                .overlay(Circle().stroke((memo.isSticker ? Color(hex: memo.stickerColorHex ?? "#F28FA9") : Color.tpInk).opacity(0.5), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(memo.text) 메모")
                        .position(
                            x: scheduleBadgeBaseX + scheduleBadgeOffset(minute: minute, isEvent: false),
                            y: min(max(y, MapHomeTimeSidebarMath.verticalInset), railHeight - MapHomeTimeSidebarMath.verticalInset)
                        )
                    }
                    ForEach(recordingShows(\.sidebarMemos) ? dayCalendarEventsForSelectedDate.filter { !$0.isAllDay } : []) { event in
                        let window = MapHomeTimeSidebarMath.visibleWindow(
                            startMinute: timeSidebarVisibleStartMinute,
                            durationMinutes: timeSidebarVisibleDurationMinutes,
                            centerMinute: effectiveTimelineMinute
                        )
                        let minute = minuteOfDay(for: event.span.start)
                        let trackHeight = max(1, railHeight - MapHomeTimeSidebarMath.verticalInset * 2)
                        let y = MapHomeTimeSidebarMath.verticalInset
                            + trackHeight * MapHomeTimeSidebarMath.position(minute: minute, window: window)
                        Button {
                            toggleSidebarNote(.event(id: "\(event.id)", title: event.title, notes: event.notes, span: event.span, minute: minute, badgeOffset: scheduleBadgeOffset(minute: minute, isEvent: true)))
                        } label: {
                            MapHomeCalendarSourceLogo()
                                .padding(3)
                                .frame(width: 22, height: 22)
                                .background(Color.white.opacity(0.96), in: Circle())
                                .overlay(Circle().stroke(Color.black.opacity(0.12), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(event.title) 일정")
                        .position(
                            x: scheduleBadgeBaseX + scheduleBadgeOffset(minute: minute, isEvent: true),
                            y: min(max(y, MapHomeTimeSidebarMath.verticalInset), railHeight - MapHomeTimeSidebarMath.verticalInset)
                        )
                    }
                    if let note = sidebarNote {
                        let window = MapHomeTimeSidebarMath.visibleWindow(
                            startMinute: timeSidebarVisibleStartMinute,
                            durationMinutes: timeSidebarVisibleDurationMinutes,
                            centerMinute: effectiveTimelineMinute
                        )
                        let y = MapHomeTimeSidebarMath.verticalInset + max(1, railHeight - MapHomeTimeSidebarMath.verticalInset * 2)
                            * MapHomeTimeSidebarMath.position(minute: note.minute, window: window)
                        MapHomeSidebarNoteBubble(note: note, onExpire: { sidebarNote = nil }) {
                            selectedMapStickerEditor = note.editorTarget
                            sidebarNote = nil
                        }
                        .position(
                            x: MapHomeSidebarNoteLayout.centerX(badgeX: scheduleBadgeBaseX + note.badgeOffset),
                            y: min(max(y, 40), railHeight - 40)
                        )
                    }
                }
                .onChange(of: timeline.date) { _, date in
                    refreshHomeGrowth(at: date)
                }
                .frame(
                    width: timeSidebarInteractionWidth,
                    height: railHeight
                )
                .position(
                    x: proxy.size.width - timeSidebarInteractionWidth / 2,
                    y: max(
                        railHeight / 2,
                        proxy.size.height - zoomReserve - railHeight / 2
                    )
                )
            }
        }
        .frame(
            width: MapHomeTimeSidebarMath.interactionWidth(
                railWidth: timeRailWidth,
                trailingInteractionWidth: Layout.horizontalInset
            )
        )
        .frame(maxHeight: .infinity, alignment: .trailing)
    }

    private func mapControls(
        proxy: MapProxy?,
        railHeight: CGFloat
    ) -> some View {
        // 검색·메모·일정은 왼쪽 상단 한 줄에 둔다(대표 지시). 아래 왼쪽 자리는 비운다.
        return Color.clear
            .frame(width: timeRailWidth, height: railHeight)
            .allowsHitTesting(false)
        .shadow(color: .black.opacity(0.045), radius: 5, y: 1)
    }

    private var timelineZoomControls: some View {
        HStack(spacing: 0) {
            timelineZoomButton(systemImage: "plus", direction: 1)
            timelineZoomButton(systemImage: "minus", direction: -1)
        }
        .background(Capsule().fill(Color.tpSurface.opacity(0.94)))
        .overlay(Capsule().stroke(Color.tpLine.opacity(0.5), lineWidth: 0.6))
        .overlay(Rectangle().fill(Color.tpLine.opacity(0.45)).frame(width: 0.6, height: 12))
    }

    private func timelineZoomButton(systemImage: String, direction: Int) -> some View {
        let durations = MapHomeTimeSidebarMath.zoomDurations
        let enabled = direction > 0
            ? timeSidebarVisibleDurationMinutes > (durations.last ?? 60)
            : timeSidebarVisibleDurationMinutes < (durations.first ?? 1_440)
        return Button {
            zoomStepToken += direction
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: TaptionType.scaled(TaptionType.snapped(9)), weight: .bold))
                .foregroundStyle(enabled ? Color.tpInk : Color.tpSecondary.opacity(0.4))
                .frame(width: timeRailWidth / 2, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(
            direction > 0
                ? language.text("시간선 확대", "Zoom timeline in")
                : language.text("시간선 축소", "Zoom timeline out")
        )
    }

    private func mapZoomButton(
        systemImage: String,
        direction: Int,
        proxy: MapProxy?
    ) -> some View {
        Button {
            adjustMapZoom(direction: direction, proxy: proxy)
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: Layout.mapControlIcon, weight: .bold))
                .foregroundStyle(Color.tpInk)
                .frame(width: Layout.mapControlSize, height: Layout.mapControlSize)
        }
        .accessibilityLabel(
            direction > 0
                ? language.text("지도 확대", "Zoom map in")
                : language.text("지도 축소", "Zoom map out")
        )
        .disabled(
            MapHomeCameraZoomMath.isAtLimit(
                distance: visibleMapCamera?.distance,
                direction: direction
            )
        )
    }

    private func adjustMapZoom(direction: Int, proxy: MapProxy?) {
        guard let camera = visibleMapCamera else { return }
        let distance = MapHomeCameraZoomMath.distance(
            from: camera.distance,
            direction: direction
        )
        guard distance != camera.distance else { return }
        recordUserMapAdjustment()
        let anchor = userTrackingMode.keepsCameraLocked || isMapCenteredOnUser
            ? displayedLocationCoordinate ?? camera.centerCoordinate
            : camera.centerCoordinate
        let center = MapHomeCameraZoomMath.centerPreservingAnchor(
            cameraCenter: camera.centerCoordinate,
            anchor: anchor,
            oldDistance: camera.distance,
            newDistance: distance
        )
        setMapPosition(.camera(
            MapCamera(
                centerCoordinate: center,
                distance: distance,
                heading: camera.heading,
                pitch: camera.pitch
            )
        ))
        updateUserCenterState(using: proxy)
    }

    private var menu: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.18)
                    .ignoresSafeArea(edges: .top)
                    .contentShape(Rectangle())
                    .onTapGesture { isMenuOpen = false }

                let menuHeight = max(0, proxy.size.height)
                let menuTop = max(Layout.headerVisibleHeight, headerFrame.maxY)
                sidebarContent
                .frame(
                    width: Layout.menuWidth(for: proxy.size.width),
                    height: max(0, menuHeight - menuTop),
                    alignment: .top
                )
                .background(Color.tpSurface.opacity(0.62))
                .mapHomeGlass(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(Color.tpLine.opacity(0.6), lineWidth: 0.8)
                }
                .padding(.top, menuTop)
                // 왼쪽 가장자리에서 펼쳐져 오른쪽 시간 사이드바를 가리지 않는다.
                .padding(.leading, Layout.horizontalInset)
                .shadow(color: Color.black.opacity(0.18), radius: 22, x: 8, y: 0)
            }
        }
    }

    private var sidebarContent: some View {
        ScrollView(showsIndicators: false) {
            MapHomeWidePanelColumns(columns: menuPanelKind.columns, spacing: 14, alignment: .leading, trailingTopInset: 0) {
            HStack(spacing: 12) {
                MapHomeMenuCatPicker(selected: model.selectedCatCoat, language: language) { model.selectCatCoat($0) }

                MapHomeMenuHeaderTitle(language: language)
                Spacer()
                Button { isMenuOpen = false } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: TaptionType.scaled(TaptionType.snapped(15)), weight: .bold))
                        .foregroundStyle(Color.tpInk.opacity(0.7))
                        .frame(width: TaptionMenuMetrics.minimumHitSize, height: TaptionMenuMetrics.minimumHitSize)
                        .mapHomeGlass(in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(language.text("메뉴 닫기", "Close menu"))
            }
            .padding(.bottom, 8)

            if !sensorCollectionPermissionGate.sensorCollectionReady, menuPanelKind.columns == 1 {
                sensorPermissionCard
                    .padding(.bottom, 10)
            }

            menuGroupLabel(language.text("기록", "Record"))
            menuGroupCard {
                locationMenuItem
                menuGroupDivider
                categoryMenuItem
            }
            menuGroupLabel(language.text("화면", "View"))
            menuGroupCard {
                displayMenuItem
                menuGroupDivider
                languageMenuItem
                menuGroupDivider
                TaptionFontMenuRow(language: language)
            }
            menuGroupLabel(language.text("연결", "Connections"))
            menuGroupCard {
                appleWatchMenuItem
                menuGroupDivider
                menuRowButton("calendar.badge.plus", language.text("캘린더 연결", "Calendar"), tint: .tpMenuChip("#3E8FDC")) { isCalendarConnectPresented = true }
                menuGroupDivider
                // 차량 오디오(블루투스·CarPlay)가 연결된 이동은 자동차로 확정한다(CAR1029A01).
                menuRowButton("car.fill", language.text("내 차 등록", "My car"), tint: .tpMenuChip("#4F86B8")) { isCarAudioSheetPresented = true }
            }
            } trailing: {
            if !sensorCollectionPermissionGate.sensorCollectionReady, menuPanelKind.columns > 1 { sensorPermissionCard.padding(.bottom, 10) }
            menuGroupLabel(language.text("앱", "App"))
            menuGroupCard {
                settingsMenuItem
                menuGroupDivider
                menuRowButton("bell.badge", language.text("알림", "Alerts"), tint: .tpMenuChip("#D9952B")) { isAlarmSettingsPresented = true }
                menuGroupDivider
                menuRowButton("photo.on.rectangle.angled", language.text("하루 카드", "Day card"), tint: .tpMenuChip("#D9627F")) { isDailyCardPresented = true }
                menuGroupDivider
                menuRowButton("info.circle", language.text("지도 출처", "Map attribution"), tint: .tpMenuChip("#8C8574")) { isMapAttributionPresented = true }
            }

            Spacer(minLength: 28)

            if TaptionCommercePolicy.supportsPaidPurchase {
                menuItem(
                    "sparkles",
                    proMenuTitle,
                    isSelected: proAccess.hasPermanentAccess
                ) {
                    proAccess.isPurchaseSheetPresented = true
                }
            }

            Divider()
                .padding(.vertical, 9)

            HStack(spacing: 8) {
                Circle()
                    .fill(currentCoordinate == nil ? Color.tpInk.opacity(0.3) : Color.tpAccent)
                    .frame(width: 7, height: 7)
                Text(
                    currentCoordinate == nil
                        ? language.text("위치 기록을 기다리는 중", "Waiting for location")
                        : language.text("현재 위치 기록 중", "Recording current location")
                )
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 9)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .mapHomeGlass(in: Capsule())

            Divider()
                .padding(.vertical, 9)

            appVersionFooter
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(MapHomeScrollBounceDisabler())
    }

    /// 메인 메뉴 묶음 제목과 카드. 항목은 카드 안에서 얇은 구분선으로 나눈다.
    /// 표시 메뉴 안의 이동 항목: 아래 토글·선택 행과 같은 글자 크기·여백·아이콘 색으로 맞춘다.
    /// 드롭다운 행: 제목과 현재 값, 위아래 화살표. 다른 메뉴 행과 같은 크기를 쓴다.
    /// 표시 > 사이드바: 사이드바에 함께 그려지는 항목과 시각 표시를 한 묶음으로 둔다(대표 지시, UIX1101A02).
    private var sidebarDisplayGroup: some View {
        VStack(alignment: .leading, spacing: 0) {
            displayGroupHeader(language.text("사이드바", "Sidebar"), systemImage: "sidebar.right", isExpanded: $isSidebarGroupExpanded)
            if isSidebarGroupExpanded {
                displayToggle(
                    language.text("날씨", "Weather"),
                    systemImage: "cloud.sun.fill",
                    isOn: Binding(
                        get: { model.settings.weatherSidebarVisible },
                        set: { model.setWeatherSidebarVisible($0) }
                    )
                )
                displayToggle(
                    language.text("메모 표시", "Show memos"),
                    systemImage: "note.text",
                    isOn: Binding(
                        get: { memoDisplayMode != .hidden },
                        set: { memoDisplayRaw = ($0 ? MapHomeMemoDisplayMode.all : .hidden).rawValue }
                    )
                )
                Menu {
                    Picker("", selection: $sidebarTimeFormatRaw) {
                        ForEach(MapHomeSidebarTimeFormat.allCases) { format in
                            Text(format.title(language)).tag(format.rawValue)
                        }
                    }
                } label: {
                    displayDropdownRow(
                        "clock",
                        language.text("시간 표시", "Time format"),
                        (MapHomeSidebarTimeFormat(rawValue: sidebarTimeFormatRaw) ?? .twentyFourHour).title(language)
                    )
                }
                .padding(.vertical, 3)
                Menu {
                    Picker("", selection: $sidebarRulerIntervalRaw) {
                        ForEach(MapHomeSidebarRulerInterval.allCases) { interval in
                            Text(interval.title(language)).tag(interval.rawValue)
                        }
                    }
                } label: {
                    displayDropdownRow(
                        "ruler",
                        language.text("시간 간격", "Time interval"),
                        (MapHomeSidebarRulerInterval(rawValue: sidebarRulerIntervalRaw) ?? .automatic).title(language)
                    )
                }
                .padding(.vertical, 3)
            }
        }
    }

    private func displayDropdownRow(_ systemImage: String, _ title: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(14)), weight: .semibold))
                .foregroundStyle(Color.tpInk)
            Spacer()
            Text(value)
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .medium))
                .foregroundStyle(Color.tpSecondary)
                .lineLimit(1)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: TaptionType.scaled(TaptionType.snapped(10)), weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(Color.tpAccent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
    }

    private func displaySubRow(_ systemImage: String, _ title: String) -> some View {
        HStack(spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(14)), weight: .semibold))
                .foregroundStyle(Color.tpInk)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
    }

    /// 메뉴 한 줄: 아이콘 상자 + 제목 + 오른쪽 화살표. 지도 출처와 같은 모양이다.
    private func menuRowButton(
        _ systemImage: String,
        _ title: String,
        tint: Color = .tpAccent,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 13) {
                MapHomeMenuIconChip(systemImage: systemImage, tint: tint)
                Text(title)
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(16)), weight: .semibold))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(Color.tpInk)
            .padding(.vertical, 9)
            .padding(.horizontal, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func menuGroupLabel(_ title: String) -> some View {
        Text(title)
            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .bold))
            .foregroundStyle(Color.tpSecondary)
            .padding(.top, 16)
            .padding(.bottom, 6)
            .padding(.horizontal, 6)
    }

    private func menuGroupCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .padding(.vertical, 2)
        .background(Color.tpSurface.opacity(0.78), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.tpLine.opacity(0.7), lineWidth: 0.8)
        }
    }

    private var menuGroupDivider: some View {
        Divider()
            .overlay(Color.tpLine.opacity(0.7))
            .padding(.leading, 57)
            .padding(.trailing, 12)
    }

    private var appVersionFooter: some View {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "-"
        let build = info?["CFBundleVersion"] as? String ?? "-"
        return Text(
            language.text(
                "BOKKI Plan \(version) (빌드 \(build))",
                "BOKKI Plan \(version) (Build \(build))"
            )
        )
        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .medium))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    private var categoryMenuItem: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button {
                isCategoryMenuExpanded.toggle()
            } label: {
                HStack(spacing: 13) {
                    MapHomeMenuIconChip(systemImage: "paintpalette.fill", tint: .tpMenuChip("#9A5B8F"))
                    Text(language.text("행동 분류", "Activity categories"))
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(16)), weight: .semibold))
                    Spacer()
                    Image(systemName: isCategoryMenuExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(Color.tpInk)
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(language.text("행동 분류 목록", "Activity category list"))

            if isCategoryMenuExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(
                        MapHomeSidebarMajorCategory.all(
                            categoryColors: model.settings.mapCategoryColors
                        )
                    ) { category in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 9) {
                                Circle()
                                    .fill(category.tint)
                                    .frame(width: 10, height: 10)
                                MapHomeStickmanGlyph(
                                    action: category.stickmanAction,
                                    size: 36,
                                    equippedAccessoryID: homeGrowthHistory.season.equippedAccessory
                                )
                                .frame(width: 60, height: MapHomeGrowthAccessoryCatalog.hatAssetName(for: homeGrowthHistory.season.equippedAccessory) == nil ? 46 : 60)
                                .clipped()
                                Text(category.localizedTitle(language))
                                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .medium))
                                Spacer()
                                Button {
                                    if activePaletteCategoryID == category.id {
                                        activePaletteCategoryID = nil
                                    } else {
                                        customPaletteColor = Color(
                                            hex: model.settings.mapCategoryColors[category.id]
                                                ?? category.hex
                                        )
                                        activePaletteCategoryID = category.id
                                    }
                                } label: {
                                    Circle()
                                        .fill(category.tint)
                                        .frame(width: 23, height: 23)
                                        .overlay {
                                            Image(systemName: activePaletteCategoryID == category.id
                                                ? "chevron.up"
                                                : "paintpalette.fill")
                                                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(9)), weight: .bold))
                                                .foregroundStyle(.white)
                                        }
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(
                                    language.text(
                                        "\(category.localizedTitle(language)) 색상 팔레트",
                                        "\(category.localizedTitle(language)) color palette"
                                    )
                                )
                            }
                            MapHomeCategoryDetailRows(categoryID: category.id, language: language, accessoryID: homeGrowthHistory.season.equippedAccessory)
                            if activePaletteCategoryID == category.id {
                                LazyVGrid(
                                    columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 6),
                                    spacing: 6
                                ) {
                                    ForEach(Self.categoryPaletteHexes, id: \.self) { hex in
                                        Button {
                                            model.setMapCategoryColor(hex, for: category.id)
                                            activePaletteCategoryID = nil
                                        } label: {
                                            Circle()
                                                .fill(Color(hex: hex))
                                                .frame(width: 22, height: 22)
                                                .overlay {
                                                    Circle()
                                                        .stroke(.white.opacity(0.9), lineWidth: 1)
                                                }
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel(language.text("색상 선택", "Choose color"))
                                    }

                                    ColorPicker(
                                        language.text("사용자 지정", "Custom"),
                                        selection: Binding(
                                            get: { customPaletteColor },
                                            set: { color in
                                                customPaletteColor = color
                                                if let hex = color.hexRGBString {
                                                    model.setMapCategoryColor(hex, for: category.id)
                                                }
                                            }
                                        ),
                                        supportsOpacity: false
                                    )
                                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(10)), weight: .semibold))
                                    .frame(maxWidth: .infinity, minHeight: 28)
                                    .padding(.horizontal, 5)
                                    .background(Color.tpInk.opacity(0.07), in: Capsule())
                                    .accessibilityLabel(
                                        language.text("사용자 지정 색상", "Custom category color")
                                    )
                                }
                                .padding(.leading, 39)
                                .padding(.bottom, 4)
                            }
                        }
                        .foregroundStyle(Color.primary)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 8)
                        .background(
                            category.tint.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                        )
                        .accessibilityElement(children: .contain)
                    }

                    Button {
                        isCategoryAddPresented = true
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: TaptionType.scaled(TaptionType.snapped(16)), weight: .semibold))
                            Text(language.text("사용자 추가", "Add custom"))
                                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .semibold))
                            Spacer()
                        }
                        .foregroundStyle(Color.tpReferenceBlue)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 8)
                    }
                    .buttonStyle(.plain)

                    ForEach(model.settings.mapUserActivityCategories) { category in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 9) {
                                Circle()
                                    .fill(Color(hex: category.hex))
                                    .frame(width: 10, height: 10)
                                TaptionCuteIcon(category.systemImage, size: 18)
                                    .foregroundStyle(Color(hex: category.hex))
                                    .frame(width: 20)
                                Text(category.title)
                                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .medium))
                                Spacer()
                                Button {
                                    if activePaletteCategoryID == category.id.uuidString {
                                        activePaletteCategoryID = nil
                                    } else {
                                        customPaletteColor = Color(hex: category.hex)
                                        activePaletteCategoryID = category.id.uuidString
                                    }
                                } label: {
                                    Image(systemName: "paintpalette.fill")
                                        .font(.system(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .semibold))
                                        .foregroundStyle(Color(hex: category.hex))
                                        .frame(width: 28, height: 28)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(language.text("\(category.title) 색상 팔레트", "\(category.title) color palette"))
                            }
                            if activePaletteCategoryID == category.id.uuidString {
                                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 6), spacing: 6) {
                                    ForEach(Self.categoryPaletteHexes, id: \.self) { hex in
                                        Button {
                                            model.setMapCategoryColor(hex, for: category.id.uuidString)
                                            activePaletteCategoryID = nil
                                        } label: {
                                            Circle().fill(Color(hex: hex)).frame(width: 22, height: 22)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    ColorPicker(language.text("사용자 지정", "Custom"), selection: Binding(
                                        get: { customPaletteColor },
                                        set: { color in
                                            customPaletteColor = color
                                            if let hex = color.hexRGBString {
                                                model.setMapCategoryColor(hex, for: category.id.uuidString)
                                            }
                                        }
                                    ), supportsOpacity: false)
                                    .frame(minHeight: 28)
                                }
                                .padding(.leading, 39)
                            }
                        }
                        .padding(.vertical, 7)
                        .padding(.horizontal, 8)
                        .background(
                            Color.tpReferenceMint.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                        )
                    }
                }
                .padding(.leading, 12)
                Text(language.text("색상을 선택하면 즉시 저장됩니다.", "Colors save immediately."))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(10.5)), weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 20)
            }
        }
    }

    private var locationMenuItem: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button {
                isLocationMenuExpanded.toggle()
            } label: {
                HStack(spacing: 13) {
                    MapHomeMenuIconChip(systemImage: "mappin.and.ellipse", tint: .tpMenuChip("#C8553D"))
                    Text(language.text("위치", "Location"))
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(16)), weight: .semibold))
                    Spacer()
                    Image(systemName: isLocationMenuExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(Color.tpInk)
                .padding(.vertical, 9)
                .padding(.horizontal, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(language.text("위치 목록", "Location list"))

            if isLocationMenuExpanded {
                VStack(spacing: 5) {
                    userLocationsMenuItem
                    ForEach(MapHomeLocationDestination.allCases.filter { $0 != .user }) { destination in
                        locationDestinationRow(destination)
                    }
                }
                .padding(.leading, 12)
            }
        }
    }

    private var userLocationsMenuItem: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button {
                isUserLocationsMenuExpanded.toggle()
            } label: {
                HStack(spacing: 10) {
                    MapHomeLocationThumbnail(
                        destination: .user,
                        size: 34
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        Text(language.text("사용자", "User"))
                            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(14)), weight: .semibold))
                        Text(
                            language.text(
                                "등록된 사용자 위치 " + String(userLocationCount) + "개",
                                String(userLocationCount) + " saved user locations"
                            )
                        )
                            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(10.5)), weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: isUserLocationsMenuExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: TaptionType.scaled(TaptionType.snapped(10)), weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(Color.primary)
                .padding(.vertical, 7)
                .padding(.horizontal, 8)
                .background(
                    Color.tpReferenceRose.opacity(0.07),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                language.text("사용자 위치 목록", "User location list")
            )

            if isUserLocationsMenuExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    if userLocationCount == 0 {
                        Text(language.text("등록된 사용자 위치가 없습니다.", "No saved user locations."))
                            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                    }

                    ForEach(userFrequentPlaces) { place in
                        userFrequentPlaceRow(place)
                    }
                    ForEach(model.settings.userTransitLocations) { location in
                        userTransitLocationRow(location)
                    }

                    Button {
                        isTransitLocationsPresented = true
                        isMenuOpen = false
                    } label: {
                        Label(
                            language.text("사용자 위치 관리", "Manage user locations"),
                            systemImage: "slider.horizontal.3"
                        )
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(11.5)), weight: .semibold))
                        .foregroundStyle(Color.tpReferenceBlue)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.leading, 12)
            }
        }
    }

    private var userFrequentPlaces: [FrequentPlace] {
        model.settings.frequentPlaces.filter {
            $0.kind == .custom
        }
    }

    private var userLocationCount: Int {
        userFrequentPlaces.count + model.settings.userTransitLocations.count
    }

    private func userFrequentPlaceRow(_ place: FrequentPlace) -> some View {
        Button {
            if let point = place.point {
                focusMap(on: point)
                isMenuOpen = false
            } else {
                selectedUserLocation = .frequentPlace(place.id)
                isMenuOpen = false
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: place.kind.systemImage)
                    .font(.system(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .semibold))
                    .foregroundStyle(
                        MapHomeLocationDestination(placeKind: place.kind)?.tint
                            ?? MapHomeLocationDestination.user.tint
                    )
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(displayedFrequentPlaceName(place))
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(12.5)), weight: .semibold))
                        .lineLimit(1)
                    Text(
                        place.point == nil
                            ? language.text("위치 미지정", "Location not set")
                            : place.kind == .restaurant
                                ? language.text("등록 식당", "Restaurant")
                                : language.text("사용자 위치", "User location")
                    )
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(9.5)), weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: place.point == nil ? "pencil" : "location.fill")
                    .font(.system(size: TaptionType.scaled(TaptionType.snapped(9)), weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(Color.primary)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }

    private func userTransitLocationRow(_ location: UserTransitLocation) -> some View {
        Button {
            focusMap(on: location.point)
            isMenuOpen = false
        } label: {
            HStack(spacing: 8) {
                Image(systemName: location.kind.systemImage)
                    .font(.system(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .semibold))
                    .foregroundStyle(Color.tpReferenceBlue)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(location.name)
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(12.5)), weight: .semibold))
                        .lineLimit(1)
                    Text(language.text(location.kind.title, location.kind.englishTitle))
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(9.5)), weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "location.fill")
                    .font(.system(size: TaptionType.scaled(TaptionType.snapped(9)), weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(Color.primary)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }

    private func locationDestinationRow(
        _ destination: MapHomeLocationDestination
    ) -> some View {
        HStack(spacing: 0) {
            Button {
                activateLocationDestination(destination)
            } label: {
                HStack(spacing: 10) {
                    MapHomeLocationThumbnail(destination: destination, size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(language.text(destination.koreanName, destination.englishName))
                            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(14)), weight: .semibold))
                        Text(locationDestinationSubtitle(destination))
                            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(10.5)), weight: .medium))
                            .foregroundStyle(destination == .user ? destination.tint : .secondary)
                    }
                    Spacer()
                }
                .foregroundStyle(Color.primary)
                .padding(.vertical, 7)
                .padding(.leading, 8)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(locationDestinationAccessibilityLabel(destination))

            if destination != .user {
                Button {
                    selectedLocationDestination = destination
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .bold))
                        .foregroundStyle(destination.tint)
                        .frame(width: 38, height: 42)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    language.text(
                        "\(destination.koreanName) 위치 편집",
                        "Edit \(destination.englishName) location"
                    )
                )
            }
        }
        .padding(.trailing, destination == .user ? 8 : 2)
        .background(
            destination.tint.opacity(destination == .user ? 0.10 : 0.055),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
    }

    private func activateLocationDestination(
        _ destination: MapHomeLocationDestination
    ) {
        let place = destination.placeKind.flatMap { kind in
            model.settings.frequentPlaces.first { $0.kind == kind }
        }
        switch MapHomeLocationActivation.resolve(
            isCurrentLocation: destination == .user,
            hasSavedPoint: place?.point != nil
        ) {
        case .currentLocation:
            focusUserLocation()
            isMenuOpen = false
        case .savedLocation:
            guard let point = place?.point else { return }
            focusMap(on: point)
            isMenuOpen = false
        case .edit:
            selectedLocationDestination = destination
        }
    }

    private func locationDestinationSubtitle(
        _ destination: MapHomeLocationDestination
    ) -> String {
        if destination == .user {
            return currentCoordinate == nil
                ? language.text("위치 확인 중", "Locating")
                : language.text("현재 위치", "Current location")
        }
        guard let kind = destination.placeKind,
              let place = model.settings.frequentPlaces.first(where: { $0.kind == kind })
        else {
            return language.text("현재 위치로 설정", "Set from current location")
        }
        if place.point != nil {
            return language.text("설정됨", "Set") + " · " + language.text(FloorLabel.korean(place.floor ?? 1), FloorLabel.english(place.floor ?? 1))
        }
        return language.text("현재 위치로 설정", "Set from current location")
    }

    private func locationDestinationAccessibilityLabel(
        _ destination: MapHomeLocationDestination
    ) -> String {
        let name = language.text(destination.koreanName, destination.englishName)
        if destination == .user {
            return language.text("\(name) 현재 위치 보기", "Show \(name) location")
        }
        if let kind = destination.placeKind,
           model.settings.frequentPlaces.first(where: { $0.kind == kind })?.point != nil {
            return language.text("\(name) 위치 보기", "Show \(name) location")
        }
        return language.text("\(name) 위치 설정", "Set \(name) location")
    }

    private var languageMenuItem: some View {
        Menu {
            ForEach(AppLanguagePreference.allCases) { option in
                Button {
                    guard languageRawValue != option.rawValue else { return }
                    languageRawValue = option.rawValue
                    AppLanguagePreference.save(option)
                } label: {
                    if option == languagePreference {
                        Label(
                            languagePreferenceTitle(option),
                            systemImage: "checkmark"
                        )
                    } else {
                        Text(languagePreferenceTitle(option))
                    }
                }
            }
        } label: {
            HStack(spacing: 13) {
                MapHomeMenuIconChip(systemImage: "globe", tint: .tpMenuChip("#4E9C8F"))
                Text(language.text("언어", "Language"))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(16)), weight: .semibold))
                Spacer()
                Text(languagePreferenceTitle(languagePreference))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .medium))
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: TaptionType.scaled(TaptionType.snapped(10)), weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(Color.tpInk)
            .padding(.vertical, 9)
            .padding(.horizontal, 12)
        }
        .accessibilityLabel(language.text("언어 선택", "Choose language"))
    }

    private func languagePreferenceTitle(
        _ preference: AppLanguagePreference
    ) -> String {
        switch preference {
        case .automatic:
            language.text("자동", "Automatic")
        case .korean:
            language.text("한국어", "Korean")
        case .english:
            "English"
        }
    }

    private var displayMenuItem: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button {
                isDisplayMenuExpanded.toggle()
            } label: {
                HStack(spacing: 13) {
                    MapHomeMenuIconChip(systemImage: "square.3.layers.3d", tint: .tpMenuChip("#C98A3F"))
                    Text(language.text("표시", "Display"))
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(16)), weight: .semibold))
                    Spacer()
                    Image(systemName: isDisplayMenuExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(Color.tpInk)
                .padding(.vertical, 9)
                .padding(.horizontal, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isDisplayMenuExpanded {
                // 지도 스타일을 맨 위에 둔다. 드롭다운은 같은 행 모양으로 통일한다.
                Menu {
                    // 판타지 지도를 맨 위에 두고, 나머지 벡터 스타일, Apple 스타일 순으로 보여 준다(대표 지시, ARC1030A04).
                    ForEach(MapDisplayStyle.openFreeMapStyles + MapDisplayStyle.appleStyles, id: \.self) { style in
                        Button {
                            model.setMapDisplayStyle(style)
                        } label: {
                            Label(mapStyleTitle(style), systemImage: mapStyleSystemImage(style))
                        }
                    }
                } label: {
                    displayDropdownRow(
                        "map.fill",
                        language.text("지도 스타일", "Map style"),
                        mapStyleTitle(model.settings.mapDisplayStyle)
                    )
                }
                .accessibilityLabel(language.text("지도 스타일 선택", "Choose map style"))

                // 안개 탐험은 지도 스타일 바로 아래에 둔다(대표 지시, ARC1030A11).
                VStack(alignment: .leading, spacing: 6) {
                    Label(
                        language.text("안개 탐험", "Fog of Exploration"),
                        systemImage: "cloud.fog.fill"
                    )
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(14)), weight: .semibold))
                    Picker("", selection: Binding(
                        get: { fogStrength },
                        set: { fogStrengthRaw = $0.rawValue }
                    )) {
                        ForEach(MapHomeFogStrength.allCases) { strength in
                            Text(language.text(strength.koreanLabel, strength.englishLabel)).tag(strength)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .tint(Color.tpAccent)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 12)


                counterMenuItem
                sidebarDisplayGroup
                mapDisplayGroup
            }
        }
    }

    /// 카운터처럼 펼치고 닫는 표시 그룹의 머리 줄.
    private func displayGroupHeader(_ title: String, systemImage: String, isExpanded: Binding<Bool>) -> some View {
        Button {
            isExpanded.wrappedValue.toggle()
        } label: {
            HStack(spacing: 8) {
                Label(title, systemImage: systemImage)
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(14)), weight: .semibold))
                    .foregroundStyle(Color.tpInk)
                Spacer()
                Image(systemName: isExpanded.wrappedValue ? "chevron.up" : "chevron.down")
                    .font(.system(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func displayToggle(_ title: String, systemImage: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Label(title, systemImage: systemImage)
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(14)), weight: .semibold))
        }
        .tint(Color.tpReferenceBlue)
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
    }

    /// 지도 위에 그리는 것들을 한 그룹으로 묶는다.
    private var mapDisplayGroup: some View {
        VStack(alignment: .leading, spacing: 0) {
            displayGroupHeader(language.text("지도", "Map"), systemImage: "map", isExpanded: $isMapGroupExpanded)
            if isMapGroupExpanded {
                displayToggle(language.text("경로", "Routes"), systemImage: "point.topleft.down.to.point.bottomright.curvepath", isOn: $showsRoutesOnMap)
                displayToggle(language.text("발자국", "Footprints"), systemImage: "pawprint.fill", isOn: $showsFootprintsOnMap)
                displayToggle(language.text("사진", "Photos"), systemImage: "photo.fill", isOn: $showsPhotosOnMap)
                // 등록한 장소의 반경 원(집·회사 등)을 켜고 끈다(대표 지시, ARC1030A10). 판타지 지도에서 그려진다.
                displayToggle(language.text("장소 반경", "Place radius"), systemImage: "circle.dashed", isOn: $showsPlaceRanges)
                // 끄면 재생 때 탈것 없이 속도에 따라 걷거나 뛴다.
                displayToggle(language.text("탈것 표시", "Show vehicles"), systemImage: "car.side.fill", isOn: $showsVehicleRides)
                displayToggle(
                    language.text("속도에 따라 가변", "Vary zoom with speed"),
                    systemImage: "plus.magnifyingglass",
                    isOn: Binding(
                        get: { (MapHomePlaybackZoomMode(rawValue: playbackZoomModeRaw) ?? .adaptive) == .adaptive },
                        set: { playbackZoomModeRaw = ($0 ? MapHomePlaybackZoomMode.adaptive : .fixed).rawValue }
                    )
                )
                Button {
                    isStrideCalibrationPresented = true
                } label: {
                    displaySubRow("shoeprints.fill", language.text("보폭 보정(걸음 → 거리)", "Stride calibration"))
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// 표시 안의 카운터 하위 메뉴. 연봉 카운터는 지금 설정 화면을 그대로 열고,
    /// 나머지 여섯 개는 켜고 끄기만 한다.
    private var counterMenuItem: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                isCounterMenuExpanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    Label(
                        language.text("카운터", "Counters"),
                        systemImage: "gauge.with.dots.needle.50percent"
                    )
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(14)), weight: .semibold))
                    .foregroundStyle(Color.tpInk)
                    Spacer()
                    Text(
                        language.text(
                            "\(enabledCounterKinds.count + (showsSalaryCounter && (salaryLive != nil || MapHomeAllowancePolicy.load().isConfigured) ? 1 : 0))개 켜짐",
                            "\(enabledCounterKinds.count + (showsSalaryCounter && (salaryLive != nil || MapHomeAllowancePolicy.load().isConfigured) ? 1 : 0)) on"
                        )
                    )
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .medium))
                    .foregroundStyle(Color.tpSecondary)
                    Image(systemName: isCounterMenuExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(language.text("카운터 메뉴 열기", "Open counter menu"))

            if isCounterMenuExpanded {
                VStack(spacing: 2) {
                    // 연봉도 다른 카운터처럼 켜고 끈다. 금액 설정은 옆 톱니로 연다(아직 설정이 없으면 켤 때 연다).
                    // 설정 톱니는 스위치 왼쪽에 둔다(대표 지시, ARC1030A04).
                    HStack(spacing: 18) {
                        Label(language.text("연봉 카운터", "Salary counter"), systemImage: "wonsign.circle.fill")
                            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .semibold))
                        Spacer(minLength: 0)
                        Button { isSalarySettingsPresented = true } label: {
                            Image(systemName: "gearshape.fill").foregroundStyle(Color.tpSecondary).frame(width: 32, height: 32)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(language.text("연봉 카운터 설정", "Salary counter settings"))
                        Toggle("", isOn: Binding(get: { showsSalaryCounter }, set: { isOn in
                            showsSalaryCounter = isOn
                            if isOn, salaryLive == nil, !MapHomeAllowancePolicy.load().isConfigured { isSalarySettingsPresented = true }
                        }))
                        .labelsHidden()
                        .tint(Color.tpAccent)
                        .accessibilityLabel(language.text("연봉 카운터", "Salary counter"))
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 12)
                    .accessibilityElement(children: .contain)

                    ForEach(MapHomeCounterKind.allCases) { kind in
                        Toggle(isOn: counterBinding(kind)) {
                            Label(kind.menuTitle(language), systemImage: kind.systemImage)
                                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .semibold))
                        }
                        .tint(Color.tpAccent)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 12)
                        .accessibilityLabel(kind.menuTitle(language))
                    }
                }
                .padding(.leading, 10)
            }
        }
    }

    private func counterBinding(_ kind: MapHomeCounterKind) -> Binding<Bool> {
        Binding(
            get: { isCounterOn(kind) },
            set: { setCounter(kind, isOn: $0) }
        )
    }

    private func isCounterOn(_ kind: MapHomeCounterKind) -> Bool {
        switch kind {
        case .steps: showsStepCounter
        case .distance: showsDistanceCounter
        case .work: showsWorkCounter
        case .study: showsStudyCounter
        case .hobby: showsHobbyCounter
        case .exercise: showsExerciseCounter
        }
    }

    private func setCounter(_ kind: MapHomeCounterKind, isOn: Bool) {
        switch kind {
        case .steps: showsStepCounter = isOn
        case .distance: showsDistanceCounter = isOn
        case .work: showsWorkCounter = isOn
        case .study: showsStudyCounter = isOn
        case .hobby: showsHobbyCounter = isOn
        case .exercise: showsExerciseCounter = isOn
        }
    }

    private var enabledCounterKinds: [MapHomeCounterKind] {
        MapHomeCounterKind.allCases.filter { isCounterOn($0) }
    }

    private var settingsMenuItem: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button { isSettingsMenuExpanded.toggle() } label: {
                HStack(spacing: 13) {
                    MapHomeMenuIconChip(systemImage: "gearshape.fill", tint: .tpMenuChip("#8A6A4F"))
                    Text(language.text("설정", "Settings"))
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(16)), weight: .semibold))
                    Spacer()
                    Image(systemName: isSettingsMenuExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(Color.tpInk)
                .padding(.vertical, 9)
                .padding(.horizontal, 12)
                .background(Color.tpInk.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(language.text("설정 목록", "Settings list"))

            if isSettingsMenuExpanded {
                Button { isDataProtectionPresented = true } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: TaptionType.scaled(TaptionType.snapped(16)), weight: .semibold))
                            .foregroundStyle(Color.tpReferenceRose)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(language.text("데이터 보호", "Data Protection"))
                                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(14)), weight: .semibold))
                            Text(dataProtectionStatusText)
                                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(10.5)), weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: TaptionType.scaled(TaptionType.snapped(10)), weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    .foregroundStyle(Color.primary)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 8)
                    .background(Color.tpReferenceRose.opacity(0.055), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(language.text("데이터 보호 열기", "Open data protection"))
                .padding(.leading, 12)

                Button { isSettingsResetConfirmationPresented = true } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: TaptionType.scaled(TaptionType.snapped(16)), weight: .semibold))
                            .foregroundStyle(Color.tpReferenceRose)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(language.text("설정 초기화", "Reset settings"))
                                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(14)), weight: .semibold))
                            Text(language.text("화면·연동 설정을 기본값으로 복원", "Restore display and integration settings"))
                                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(10.5)), weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: TaptionType.scaled(TaptionType.snapped(10)), weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    .foregroundStyle(Color.primary)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 8)
                    .background(Color.tpReferenceRose.opacity(0.055), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(language.text("설정 초기화", "Reset settings"))
                .padding(.leading, 12)

                gpsLoggingMenuItem.padding(.leading, 12)
            }
        }
    }

    private var appleWatchMenuItem: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                model.refreshAppleWatchConnectionState()
                isAppleWatchMenuExpanded.toggle()
            } label: {
                HStack(spacing: 13) {
                    MapHomeMenuIconChip(systemImage: "applewatch", tint: .tpMenuChip("#6FA84F"))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(language.text("Apple Watch 데이터", "Apple Watch data"))
                            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(16)), weight: .semibold))
                        Text(appleWatchDataStatusText)
                            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: isAppleWatchMenuExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(Color.tpInk)
                .padding(.vertical, 9)
                .padding(.horizontal, 12)
                .background(Color.tpInk.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isAppleWatchMenuExpanded {
                Toggle(isOn: $isAppleWatchLinkEnabled) {
                    Text(language.text("Apple Watch 연동", "Apple Watch link"))
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .semibold))
                }
                .tint(Color.tpAccent)
                .padding(.horizontal, 12)
                Button {
                    if model.settings.healthEnabled {
                        model.requestWatchDataSync(source: "map_watch_card")
                    } else {
                        Task { await model.requestHealth() }
                    }
                } label: {
                    Text(language.text("지금 가져오기", "Import now")).frame(maxWidth: .infinity).padding(.vertical, 10)
                        .background(Color.tpAccent.opacity(0.10), in: Capsule()).contentShape(Capsule())
                }
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .bold))
                .foregroundStyle(Color.tpAccent)
                .lineLimit(1)
                .padding(.horizontal, 12)
            }
        }
    }

    /// "사용 가능 · 10월 19일 오후 4:51 가져옴" / "사용 불가"
    private var appleWatchDataStatusText: String {
        let available: Bool
        switch model.appleWatchConnectionState {
        case .unsupported, .notPaired: available = false
        case .appNotInstalled, .noRecentData, .background, .reachable: available = model.settings.healthEnabled
        }
        guard available else { return language.text("사용 불가", "Unavailable") }
        guard let fetched = model.lastHealthRefreshAt else {
            return language.text("사용 가능", "Available")
        }
        let stamp = fetched.formatted(
            .dateTime.month().day().hour().minute().locale(language.locale)
        )
        return language.text("사용 가능 · \(stamp) 가져옴", "Available · fetched \(stamp)")
    }

    private var dataProtectionStatusText: String {
        if model.securityStatus.settings.lockOnLaunch {
            return language.text("앱 열 때마다 잠금", "Locks whenever the app opens")
        }
        return model.securityStatus.hasPIN
            ? language.text("비밀번호 등록됨", "Password registered")
            : language.text("보호 설정 안 됨", "Not configured")
    }

    private var proMenuTitle: String {
        switch proAccess.menuPresentation {
        case .purchase:
            language.text("Pro 구매", "Buy Pro")
        case .trial(let remainingDays):
            language.text(
                "14일 무료 체험 · \(remainingDays)일 남음",
                "14-day free trial · \(remainingDays) days left"
            )
        case .purchased:
            language.text("Pro 구매 완료", "Pro purchased")
        }
    }

    private var sensorCollectionPermissionGate: RequiredPermissionGate {
        model.requiredPermissionGate(liveActivitiesEnabled: false)
    }

    private var sensorPermissionCard: some View {
        let missing = sensorCollectionPermissionGate.sensorCollectionMissing
        return VStack(alignment: .leading, spacing: 8) {
            Label(
                language.text("자동 기록 권한", "Automatic recording permissions"),
                systemImage: "sensor.fill"
            )
            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(14)), weight: .semibold))
            .foregroundStyle(Color.tpAccent)

            Text(
                language.text(
                    "수동 기록과 지도 메모는 지금 사용할 수 있습니다. 자동 기록을 켜려면 필요한 권한만 허용하세요.",
                    "Manual records and map memos are available now. Allow only the permissions needed for automatic recording."
                )
            )
            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .medium))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            ForEach(missing, id: \.rawValue) { permission in
                Button {
                    guard requestingPermission == nil else { return }
                    requestingPermission = permission
                    Task { @MainActor in
                        await model.requestRequiredPermission(permission)
                        requestingPermission = nil
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: sensorPermissionIcon(permission))
                            .frame(width: 20)
                        Text(sensorPermissionTitle(permission))
                        Spacer(minLength: 4)
                        if requestingPermission == permission {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text(sensorPermissionActionTitle(permission))
                                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(10)), weight: .bold))
                        }
                    }
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .medium))
                    .foregroundStyle(Color.primary)
                    .padding(.horizontal, 9)
                    .frame(minHeight: 36)
                    .background(
                        Color.tpSurface.opacity(0.9),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
                .disabled(
                    requestingPermission != nil
                        || model.isRefreshingIntegrations
                )
                .accessibilityLabel(
                    language.text(
                        "\(sensorPermissionTitle(permission)) 권한 요청",
                        "Request \(sensorPermissionTitle(permission)) permission"
                    )
                )
            }
        }
        .padding(12)
        .background(
            Color.tpInk.opacity(0.05),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .accessibilityElement(children: .contain)
    }

    private func sensorPermissionIcon(_ permission: RequiredPermission) -> String {
        switch permission {
        case .locationAlways, .locationPrecise:
            "location.fill"
        case .motion:
            "figure.walk.motion"
        case .healthKitRequestCompleted, .calendar, .notifications, .liveActivities:
            "checkmark"
        }
    }

    private func sensorPermissionTitle(_ permission: RequiredPermission) -> String {
        switch permission {
        case .locationAlways:
            language.text("위치 항상 허용", "Always Location")
        case .locationPrecise:
            language.text("정확한 위치", "Precise Location")
        case .motion:
            language.text("동작 및 피트니스", "Motion & Fitness")
        case .healthKitRequestCompleted, .calendar, .notifications, .liveActivities:
            ""
        }
    }

    private func sensorPermissionActionTitle(_ permission: RequiredPermission) -> String {
        switch permission {
        case .locationPrecise:
            language.text("설정 열기", "Open Settings")
        default:
            language.text("허용하기", "Allow")
        }
    }

    private var gpsLoggingMenuItem: some View {
        let isLogging = model.sensorCollectionSessionState == .collecting
        let tint = Color.tpReferenceRose
        let preferences = model.settings.gpsLoggingPreferences
        return VStack(spacing: 8) {
            Button {
                isGPSLoggingMenuExpanded.toggle()
            } label: {
                HStack(spacing: 13) {
                    Image(systemName: isLogging ? "location.fill" : "location.viewfinder")
                        .font(.system(size: TaptionType.scaled(TaptionType.snapped(20)), weight: .semibold))
                        .foregroundStyle(tint)
                        .frame(width: 24)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(language.text("GPS 및 센서 데이터", "GPS & Sensor Data"))
                                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(16)), weight: .semibold))
                        Text(sensorCollectionStatusText)
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .medium))
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(
                        systemName: isGPSLoggingMenuExpanded
                            ? "chevron.up"
                            : "chevron.down"
                    )
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .bold))
                    .foregroundStyle(.secondary)
                }
                .foregroundStyle(Color.primary)
                .padding(.vertical, 12)
                .padding(.horizontal, 12)
                .background(
                    tint.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 12)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                language.text(
                    "GPS 및 센서 데이터 설정",
                    "GPS and sensor settings"
                )
            )
            .accessibilityValue(
                gpsLoggingIntervalText(preferences.effectiveIntervalSeconds)
            )

            if isGPSLoggingMenuExpanded {
                GPSLoggingIntervalSlider(
                    seconds: preferences.intervalSeconds,
                    tint: tint,
                    onCommit: model.setGPSLoggingIntervalSeconds
                ) {
                    Image(systemName: "battery.25percent")
                        .foregroundStyle(tint)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
        }
    }

    private var sensorCollectionStatusText: String {
        guard sensorCollectionPermissionGate.sensorCollectionReady else {
            return language.text("권한 필요", "Permission needed")
        }
        return switch model.sensorCollectionSessionState {
        case .waiting:
            language.text("대기", "Waiting")
        case .collecting:
            language.text("수집 중", "Collecting")
        case .stopped:
            language.text("종료", "Stopped")
        }
    }

    private func gpsLoggingIntervalText(_ seconds: Int) -> String {
        let interval = GPSLoggingPreferences.intervalText(seconds)
        return language.text(
            "\(interval)마다 위치 확인",
            "Checks location every \(interval)"
        )
    }

    @ViewBuilder
    private func menuItem(_ icon: String, _ title: String, isSelected: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: TaptionType.scaled(TaptionType.snapped(18)), weight: .semibold))
                    .foregroundStyle(isSelected ? Color.tpAccent : Color.tpInk.opacity(0.55))
                    .frame(width: 26, alignment: .center)
                Text(title)
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(16)), weight: isSelected ? .bold : .medium))
                    .foregroundStyle(isSelected ? Color.tpAccent : Color.tpInk)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .semibold))
                    .foregroundStyle(Color.tpInk.opacity(0.28))
            }
            .padding(.vertical, 13)
            .padding(.horizontal, 13)
            .background(
                isSelected ? Color.tpAccent.opacity(0.12) : .clear,
                in: RoundedRectangle(cornerRadius: 13, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }

    private var placeAnnotations: [MapHomePlaceAnnotation] {
        let probe = MapHomePlaybackProbe.begin("placeAnnotations"); defer { MapHomePlaybackProbe.end(probe) }
        // 날씨는 분 단위로만 본다. 매 호출마다 날씨 전체를 훑지 않는다(ARC1030A01).
        let homeWeather = homeWeatherBadgeMemo.value(for: MapHomeHomeWeatherKey(
            minute: Int(Date.now.timeIntervalSinceReferenceDate / 60),
            weatherCount: model.snapshot.weather.count,
            lastObservedAt: model.snapshot.weather.last?.observedAt
        )) {
            MapHomeHomeWeatherBadgePolicy.badge(from: model.snapshot.weather, now: .now)
        }
        return model.settings.frequentPlaces.compactMap { place in
            guard let destination = MapHomeLocationDestination(placeKind: place.kind),
                  let point = place.point,
                  isValid(point) else { return nil }
            return MapHomePlaceAnnotation(
                id: place.id,
                name: displayedFrequentPlaceName(place),
                floor: place.floor,
                destination: destination,
                growthLevel: destination == .home
                    ? homeGrowthHistory.season.level
                    : nil,
                isLeapDay: MapHomeGrowthPolicy.isLeapDay(
                    model.selectedDate,
                    calendar: MapHomeGrowthPolicy.localCalendar
                ),
                growthStatus: destination == .home
                    ? homeGrowthMarkerStatus
                    : nil,
                isGrowthQualifiedToday: destination == .home
                    && isHomeGrowthQualifiedToday,
                growthStreak: destination == .home
                    ? homeGrowthHistory.season.streak
                    : 0,
                pendingWeeklyRewards: destination == .home
                    ? homeGrowthHistory.season.pendingWeeklyRewards
                    : 0,
                isCatAtHome: destination == .home && isDisplayedCatAtHome,
                catAction: displayedStickmanAction,
                equippedAccessoryID: homeGrowthHistory.season.equippedAccessory,
                coordinate: CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude),
                weatherBadge: destination == .home ? homeWeather : nil,
                homeSky: destination == .home ? MapHomeHomeSkyInput(
                    coordinate: CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude),
                    selectedDay: model.selectedDate,
                    progress: playbackProgress,
                    isPlaybackRunning: isDayPlaybackRunning
                ) : nil
            )
        }
    }

    /// 하루 요약 카드의 집. 지도 핀을 그대로 줄인다.
    private var daySummaryHomeArtwork: some View {
        let point = model.settings.frequentPlaces.first { $0.kind == .home }?.point
        return MapHomePlacePin(
            name: language.text("집", "Home"), floor: nil, destination: .home, growthLevel: homeGrowthHistory.season.level,
            weatherBadge: MapHomeHomeWeatherBadgePolicy.badge(from: model.snapshot.weather, now: .now),
            homeSky: point.map {
                MapHomeHomeSkyInput(coordinate: CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude),
                    selectedDay: model.selectedDate, progress: playbackProgress, isPlaybackRunning: false)
            }
        )
        // 지도 아이콘과 같은 크기. 번지는 빛은 칸 밖으로 나가도 된다.
        .frame(width: 96, height: 112)
        .allowsHitTesting(false)
    }

    private var playbackMomentEvents: [(minute: Double, moment: MapHomePlaybackMomentsOverlay.Moment)] {
        let start = Calendar.autoupdatingCurrent.startOfDay(for: model.selectedDate)
        let photos = photoMoments.map { ($0.capturedAt.timeIntervalSince(start) / 60, MapHomePlaybackMomentsOverlay.Moment.photo(id: $0.id)) }
        let memos = timedMemosForSelectedDate.map { ($0.occurredAt.timeIntervalSince(start) / 60, MapHomePlaybackMomentsOverlay.Moment.memo(text: $0.text)) }
        return (photos + memos).sorted { $0.0 < $1.0 }.map { (minute: $0.0, moment: $0.1) }
    }

    private var isDisplayedCatAtHome: Bool {
        // 구동기 재생 중에는 집 반경에 들어와도 화랑이를 숨기지 않고 마지막 위치까지 보여 준다(대표 지시, ARC1030A02).
        guard playbackDriver == nil,
              recordingShows(\.placeIcons),
              let current = displayedLocationCoordinate,
              let home = model.settings.frequentPlaces.first(where: { $0.kind == .home }),
              let point = home.point else { return false }
        return MapHomePresencePolicy.isAtHome(
            current: current,
            home: CLLocationCoordinate2D(
                latitude: point.latitude,
                longitude: point.longitude
            ),
            radiusMeters: home.radiusMeters
        )
    }

    private var homeGrowthMarkerStatus: String {
        let calendar = MapHomeGrowthPolicy.localCalendar
        let history = homeGrowthHistory
        let today = Date.now
        guard calendar.isDate(model.selectedDate, inSameDayAs: today),
              history.season.pendingDay
                == MapHomeGrowthPolicy.dayKey(today, calendar: calendar),
              history.season.pendingDayQualified else {
            return language.text("오늘 기록을 쌓아보세요", "Build today's log")
        }
        return language.text("오늘 성장 조건 충족", "Today's growth goal met")
    }

    private var isHomeGrowthQualifiedToday: Bool {
        let calendar = MapHomeGrowthPolicy.localCalendar
        let today = Date.now
        let history = homeGrowthHistory
        return calendar.isDate(model.selectedDate, inSameDayAs: today)
            && history.season.pendingDay
                == MapHomeGrowthPolicy.dayKey(today, calendar: calendar)
            && history.season.pendingDayQualified
    }

    private func displayedFrequentPlaceName(_ place: FrequentPlace) -> String {
        guard place.kind == .restaurant else { return place.name }
        let name = place.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name == "사용자 지점"
            || name.caseInsensitiveCompare("User location") == .orderedSame {
            return "식당"
        }
        return name
    }

    private var transitAnnotations: [MapHomeTransitAnnotation] {
        model.settings.userTransitLocations.compactMap { location in
            guard isValid(location.point) else { return nil }
            return MapHomeTransitAnnotation(
                id: location.id,
                name: location.name,
                kind: location.kind,
                coordinate: CLLocationCoordinate2D(
                    latitude: location.point.latitude,
                    longitude: location.point.longitude
                )
            )
        }
    }

    private var transitBoardingReadings: [SensorReading] {
        var seen = Set<UUID>()
        return (
            routeReadings
                + model.liveRouteState.readings
                + (model.latestSensorReading.map { [$0] } ?? [])
        )
        .filter {
            RouteTimelineTimestamp.isValid($0.timestamp)
                && seen.insert($0.id).inserted
        }
        .sorted { $0.timestamp < $1.timestamp }
    }

    private var transitBoardingCandidates: [TransitBoardingCandidate] {
        let probe = MapHomePlaybackProbe.begin("boardingCandidates"); defer { MapHomePlaybackProbe.end(probe) }
        let dayData = currentDayDataSnapshot
        let registeredLocations = model.settings.userTransitLocations
        let nearbyPlaces = nearbyTransitPlaces
        let travel = dayData?.travel ?? []
        let decisions = model.settings.transitBoardingDecisions
        let cutoff = routeOverlayCutoff
        let group = MapHomeTransitBoardingGroup(
            dayProjectionRevision: model.dayProjectionRevision,
            settingsHash: {
                var hasher = Hasher()
                hasher.combine(registeredLocations)
                hasher.combine(decisions)
                return hasher.finalize()
            }(),
            readingsRevision: transitBoardingReadingsRevision,
            nearbyPlacesRevision: nearbyTransitPlacesRevision,
            day: Calendar.autoupdatingCurrent.startOfDay(for: model.selectedDate)
        )
        let step = MapHomeTransitBoardingRefreshPolicy.cutoffBucket(cutoff)
        // 분이 바뀔 때마다 후보를 다시 찾으면 한 번에 50ms씩 메인 스레드를 막았다. 같은 묶음 안에서는 이전 값을 먼저 보여 주고
        // 새 분의 값은 뒤에서 만든다(ARC1030A01). 하루 기록 정리도 묶음이 바뀔 때만 한다.
        let readings = transitBoardingReadingsMemo.value(
            for: readingsSignature(sourceRevision: group.readingsRevision)
        ) { transitBoardingReadings }
        // 진단 기록은 재생 중이 아닐 때 그 자리 계산분에만 남긴다(기록용 계산도 하루 기록을 여러 번 훑는다).
        let isPlaying = isDayPlaybackRunning
        transitBoardingDerived.onFresh = { candidates in
            guard !isPlaying else { return }
            var fields = transitBoardingDiagnostics(
                readings: readings,
                registeredLocations: registeredLocations,
                nearbyPlaces: nearbyPlaces,
                travel: travel,
                through: cutoff
            )
            fields["candidate_count"] = String(candidates.count)
            fields["candidate_names"] = Array(Set(candidates.map(\.name))).sorted().joined(separator: ";")
            fields["candidate_travel_segment_count"] = String(Set(candidates.flatMap(\.travelSegmentIDs)).count)
            fields["decision_count"] = String(decisions.count)
            TaptionPlanDiagnosticsLogger.shared.record("transit_boarding_candidates_evaluated", fields: fields)
        }
        transitBoardingDerived.onUpdate = {
            if !isDayPlaybackRunning { derivedUpdateTick &+= 1 }
        }
        return transitBoardingDerived.value(group: group, step: step) {
            TransitBoardingCandidateEngine.candidates(
                readings: readings,
                registeredLocations: registeredLocations,
                nearbyPlaces: nearbyPlaces,
                travel: travel,
                decisions: decisions,
                through: cutoff
            )
        }
    }

    private func refreshTransitBoardingCandidatesIfNeeded(at date: Date) -> Bool {
        guard scenePhase == .active else { return false }
        guard MapHomeTransitBoardingRefreshPolicy.shouldRefresh(
            lastRefresh: lastTransitBoardingLiveRefreshAt,
            at: date
        ) else { return false }
        lastTransitBoardingLiveRefreshAt = date
        transitBoardingReadingsRevision &+= 1
        return true
    }

    private func transitBoardingDiagnostics(
        readings: [SensorReading],
        registeredLocations: [UserTransitLocation],
        nearbyPlaces: [TransitBoardingPlace],
        travel: [TravelSegment],
        through cutoff: Date
    ) -> [String: String] {
        let withPoint = readings.filter { $0.point != nil }
        let gpsAvailable = readings.filter(\.gpsAvailable)
        let precise = readings.filter {
            $0.locationFixQuality != .approximate
        }
        let usable = readings.filter { reading in
            guard reading.gpsAvailable,
                  reading.locationFixQuality != .approximate,
                  let point = reading.point,
                  point.latitude.isFinite,
                  point.longitude.isFinite,
                  (-90...90).contains(point.latitude),
                  (-180...180).contains(point.longitude) else {
                return false
            }
            return point.horizontalAccuracy <= 0
                || point.horizontalAccuracy <= 200
        }
        let poweredModes: Set<TravelMode> = [
            .bus, .subway, .taxi, .car, .train, .airplane, .ship,
        ]
        let poweredTravel = travel.filter {
            poweredModes.contains($0.mode)
        }
        let stationNames = Array(Set(
            (registeredLocations.map(\.name)
                + nearbyPlaces.map(\.name)
                + readings.compactMap(\.nearbyStationName))
                .map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                .filter { !$0.isEmpty }
        )).sorted().joined(separator: ";")
        return [
            "cutoff": String(cutoff.timeIntervalSince1970),
            "readings": String(readings.count),
            "readings_with_point": String(withPoint.count),
            "readings_gps_available": String(gpsAvailable.count),
            "readings_precise": String(precise.count),
            "readings_usable": String(usable.count),
            "registered_transit_places": String(registeredLocations.count),
            "nearby_transit_places": String(nearbyPlaces.count),
            "transit_place_names": stationNames,
            "travel_segments": String(travel.count),
            "travel_powered_segments": String(poweredTravel.count),
            "travel_unconfirmed_powered_segments": String(
                poweredTravel.filter { !$0.isConfirmed }.count
            ),
            "travel_mode_counts": transitModeCounts(travel.map(\.mode)),
            "reading_station_name_count": String(
                Set(readings.compactMap(\.nearbyStationName)).count
            ),
            "reading_rail_match_count": String(
                readings.filter(\.matchesRailRoute).count
            ),
            "reading_transit_match_count": String(
                readings.filter(\.matchesPublicTransitRoute).count
            ),
        ]
    }

    private func transitModeCounts(_ modes: [TravelMode]) -> String {
        let counts = Dictionary(grouping: modes, by: { $0 })
        return TravelMode.allCases.compactMap { mode in
            guard let count = counts[mode]?.count else { return nil }
            return "\(mode.rawValue)=\(count)"
        }.joined(separator: ",")
    }

    private var currentCoordinate: CLLocationCoordinate2D? {
        let readings = currentMapLocationReading.map { [$0] } ?? []
        let temporaryLocations = SubwayStationCatalog.temporaryLocations(from: readings)
        let point = MapCurrentLocationAnchorPolicy.latestValidReading(
            in: readings
        )?.point ?? RealtimeSensorMapProjection.project(
            readings: readings,
            at: .now,
            temporaryLocations: temporaryLocations
        )?.point
        guard let point, isValid(point) else { return nil }
        return CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
    }

    /// GPS를 아직 못 받았을 때 화랑이가 있을 가장 최근 위치(최신 센서 → 실시간 경로 → 오늘 경로 마지막 점).
    private var lastKnownCoordinate: CLLocationCoordinate2D? {
        let candidates: [() -> GeoPoint?] = [
            { model.latestSensorReading?.point },
            { model.liveRouteState.readings.last?.point },
            { displayRouteReadings.last(where: { $0.point != nil })?.point },
            { currentDayReadings.last(where: { $0.point != nil })?.point },
        ]
        // 앞 후보로 정해지면 하루치 병합·정렬(currentDayReadings)은 계산하지 않는다.
        for candidate in candidates {
            if let point = candidate(), isValid(point) {
                return CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
            }
        }
        return nil
    }

    /// 위치 버튼·따라가기가 맞출 좌표: 확정 현재 위치, 없으면 가장 최근 위치.
    private var liveFocusCoordinate: CLLocationCoordinate2D? {
        currentCoordinate ?? lastKnownCoordinate
    }

    private var hasConfirmedCurrentGPS: Bool {
        MapHomeCurrentGPSPolicy.isConfirmed(
            in: currentMapLocationReading.map { [$0] } ?? []
        )
    }

    private func currentActivity(at minute: Int) -> MapHomeTimeSidebarActivity {
        let segment = MapHomeTimeRailSegmentEngine.segment(
            at: minute,
            in: timeRailSegments
        ) ?? .wholeDayUnconfirmed
        return .majorCategory(
            segment.categoryID,
            accessibilityLabel: segment.title,
            categoryColors: model.settings.mapCategoryColors
        )
    }

    private func mapCategoryColor(_ id: String) -> Color {
        Color(
            hex: model.settings.mapCategoryColors[id]
                ?? MapHomePastelPalette.hex(id)
        )
    }

    private func refreshTimeRailSegments() {
        guard scenePhase == .active else { return }
        guard model.isBootstrapped else {
            if !timeRailSegments.isEmpty {
                timeRailSegments = []
            }
            return
        }
        let dayData = currentDayDataSnapshot
        let next = MapHomeTimeRailSegmentEngine.segments(
            from: dayData?.actuals ?? [],
            travel: dayData?.travel ?? [],
            on: model.selectedDate
        )
        if next != timeRailSegments {
            timeRailSegments = next
        }
    }

    private func resetDayScopedMapState(for date: Date) {
        routeReadingsPreparationTask?.cancel()
        routeReadingsPreparationTask = nil
        routeReadingsPreparationGeneration.advance()
        dayDataSnapshot = nil
        routeActualIndex = nil
        routeReadings = []
        normalizedRouteReadings = []
        currentMapLocationReading = nil
        historicalPlaybackReadings = []
        displayRouteReadings = []
        lastPreparedRouteReadingsSignature = nil
        selectedPawprintTimestamp = nil
        highlightedPawprintTimestamp = nil
        selectedPawprintCoordinate = nil
        routeProjection = nil
        wbsPlaybackProjection = nil
        timelineRouteOverlays = []
        cachedTemporaryLocations = []
        expectedRouteOverlays = []
        wbsGeneratedRouteOverlays = []
        pendingForecastRouteState = nil
        expectedRouteCache.removeAll(keepingCapacity: true)
        expectedRouteRefreshTask?.cancel()
        expectedRouteRefreshTask = nil
        expectedRouteRefreshGeneration &+= 1
        wbsExpectedRouteRequests = []
        wbsExpectedRouteRequestsInputKey = nil
        liveRouteProjectionRefreshTask?.cancel()
        liveRouteProjectionRefreshTask = nil
        nearbyTransitPlaces = []
        hasDeferredWBSPlaybackRefresh = false
        timeRailSegments = []
        timeSidebarVisibleStartMinute = 0
        timeSidebarVisibleDurationMinutes = MapHomeTimeSidebarMath.fullDayMinutes
        zoomResetToken += 1
        hasAppliedInitialMapFocus = false
        routeDocumentProjectionGate.reset()
        mapRenderCache.invalidateRouteData()
    }

    /// 표시 전용 하루 기록(카운터·요약). 오늘은 기록이 쌓일 때마다 revision이 올라 `currentDayDataSnapshot`이 순간순간 nil이 되고,
    /// 그때마다 카운터 합계가 0으로 떨어져 업무시간 카운터가 사라졌다 생겼다 했다. 낡았어도 같은 날의 마지막 기록을 쓴다(대표 지적, ARC1030A07).
    private var displayDayDataSnapshot: PlanDayDataSnapshot? {
        if let current = currentDayDataSnapshot { return current }
        guard let dayDataSnapshot,
              dayDataSnapshot.projectionVersion == TaptionPlanV3Store.projectionVersion,
              Calendar.autoupdatingCurrent.isDate(dayDataSnapshot.day, inSameDayAs: model.selectedDate) else { return nil }
        return dayDataSnapshot
    }

    private var currentDayDataSnapshot: PlanDayDataSnapshot? {
        // 오늘 기록이 쌓일 때마다 revision이 올라 지난 날짜 스냅샷이 매번 낡은 것으로 판정돼, 사이드바 대분류와
        // 재생 경로가 비었다. 지난 날짜의 완전한 스냅샷은 낡았어도 새로 만들어질 때까지 그대로 쓴다(ARC1030A02).
        guard let dayDataSnapshot,
              dayDataSnapshot.sourceRevision == model.dayProjectionRevision
                || (!model.isBootstrapped && dayDataIsPreview && model.hasPreparedStartupSettings)
                || (dayDataSnapshot.isComplete && !Calendar.autoupdatingCurrent.isDateInToday(model.selectedDate)),
              dayDataSnapshot.projectionVersion == TaptionPlanV3Store.projectionVersion,
              Calendar.autoupdatingCurrent.isDate(
                  dayDataSnapshot.day,
                  inSameDayAs: model.selectedDate
              ) else { return nil }
        return dayDataSnapshot
    }

    private var isDayDataLoading: Bool {
        guard case let .loading(day) = routeReadingsLoadState else {
            return false
        }
        return Calendar.autoupdatingCurrent.isDate(
            day,
            inSameDayAs: model.selectedDate
        )
    }

    /// 하루 센서 기록(저장분 + 실시간분)을 합쳐 정렬한 값. 합치기는 기록 수천 개를 복사·정렬해서, 본문이 매번 부르면
    /// 재생 중 메인 스레드의 28%를 썼다(Time Profiler, ARC1030A01). 입력이 같으면 만들어 둔 값을 그대로 돌려준다.
    private var currentDayReadings: [SensorReading] {
        let probe = MapHomePlaybackProbe.begin("currentDayReadings"); defer { MapHomePlaybackProbe.end(probe) }
        guard let dayData = currentDayDataSnapshot else {
            return historicalPlaybackReadings
        }
        let calendar = Calendar.autoupdatingCurrent
        let start = calendar.startOfDay(for: model.selectedDate)
        let key = MapHomeDayReadingsCache.Key(
            day: start, sourceRevision: dayData.sourceRevision, storedCount: dayData.readings.count,
            liveCount: model.liveRouteState.readings.count, liveLastID: model.liveRouteState.readings.last?.id,
            latestID: model.latestSensorReading?.id
        )
        if let cached = dayReadingsCache.value(for: key) { return cached }
        let end = calendar.date(byAdding: .day, value: 1, to: start)
            ?? start.addingTimeInterval(24 * 60 * 60)
        let merged = MapHomeRouteReadingsPolicy.merging(
            existing: dayData.readings,
            loaded: model.liveRouteState.readings
                + (model.latestSensorReading.map { [$0] } ?? []),
            in: TimeSpan(start: start, end: end)
        )
        dayReadingsCache.store(merged, for: key)
        return merged
    }

    private func refreshSelectedTimelineMapPosition(
        minute: Int?,
        using proxy: MapProxy? = nil
    ) {
        let deferredProjection = flushDeferredRouteProjection()
        guard minute != nil else { return }
        _ = deferredProjection
            ?? refreshRouteProjection()
        recordCurrentPlaybackAlignment()
        guard let point = displayedPlaybackFocusPoint else { return }
        focusMap(on: point, using: proxy, followsTracking: true)
    }

    private func openSectionEditor(at minute: Int) {
        guard model.isBootstrapped else { return }
        stopDayPlayback(resetProgress: true)
        let segment = MapHomeTimeRailSegmentEngine.segment(
            at: minute,
            in: timeRailSegments
        ) ?? .wholeDayUnconfirmed
        TaptionPlanDiagnosticsLogger.shared.record(
            "section_edit_open_requested",
            fields: [
                "minute": String(minute),
                "category": segment.categoryID,
                "source_count": String(segment.sourceIDs.count),
            ]
        )
        sectionEditSelection = MapHomeSectionEditSelection(
            date: model.selectedDate,
            minute: minute,
            activity: currentActivity(at: minute),
            segment: segment,
            details: sectionDetails(at: minute),
            daySegments: timeRailSegments,
            dayDetails: allDaySectionDetails()
        )
    }

    private var visibleExpectedRouteOverlays: [MapHomeExpectedRouteOverlay] {
        guard Calendar.autoupdatingCurrent.isDateInToday(model.selectedDate) else { return [] }
        let cutoff = routeOverlayCutoff
        return mapRenderCache.visibleExpectedRoutes(cutoff: cutoff) {
            expectedRouteOverlays.compactMap {
                $0.visible(through: cutoff)
            }
        }.filter { visible in
            !hasRouteDecision(predictedRoute(for: expectedRouteOverlays.first { $0.id == visible.id } ?? visible))
        }
    }

    private var displayedExpectedRouteOverlays: [MapHomeExpectedRouteOverlay] {
        Array(
            visibleExpectedRouteOverlays.prefix(
                MapHomeForecastRouteDisplayPolicy.maximumVisibleRoutes
            )
        )
    }

    private var visibleWBSGeneratedRouteOverlays: [MapHomeWBSGeneratedRouteOverlay] {
        guard Calendar.autoupdatingCurrent.isDateInToday(model.selectedDate) else { return [] }
        let cutoff = routeOverlayCutoff
        return wbsGeneratedRouteOverlays.filter { !hasRouteDecision(predictedRoute(for: $0)) }.compactMap {
            $0.visible(through: cutoff)
        }
    }

    private var displayedWBSGeneratedRouteOverlays: [MapHomeWBSGeneratedRouteOverlay] {
        let remaining = max(
            0,
            MapHomeForecastRouteDisplayPolicy.maximumVisibleRoutes
                - displayedExpectedRouteOverlays.count
        )
        return Array(visibleWBSGeneratedRouteOverlays.prefix(remaining))
    }

    private func scheduleExpectedRouteRefresh() {
        expectedRouteRefreshGeneration &+= 1
        let refreshGeneration = expectedRouteRefreshGeneration
        if pendingForecastRouteState != nil {
            pendingForecastRouteState = nil
        }
        expectedRouteRefreshTask?.cancel()
        guard scenePhase == .active else {
            expectedRouteRefreshTask = nil
            return
        }
        expectedRouteRefreshTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 100_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled,
                  scenePhase == .active,
                  refreshGeneration == expectedRouteRefreshGeneration else {
                return
            }
            await refreshExpectedRouteOverlays(generation: refreshGeneration)
            guard !Task.isCancelled,
                  refreshGeneration == expectedRouteRefreshGeneration else {
                return
            }
            expectedRouteRefreshTask = nil
        }
    }

    private func currentExpectedRouteInputKey() -> MapHomeExpectedRouteInputKey {
        let calendar = Calendar.autoupdatingCurrent
        let selectedDay = calendar.startOfDay(for: model.selectedDate)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: selectedDay)
            ?? selectedDay.addingTimeInterval(24 * 60 * 60)
        let dayData = currentDayDataSnapshot
        let liveReadings = model.liveRouteState.readings
        let latestReading = model.latestSensorReading
        return MapHomeExpectedRouteInputKey(
            selectedDay: selectedDay,
            dayEnd: dayEnd,
            dayProjectionRevision: model.dayProjectionRevision,
            daySourceRevision: dayData?.sourceRevision,
            daySourceUpdatedAt: dayData?.sourceUpdatedAt,
            daySourceFingerprint: dayData?.sourceFingerprint,
            isPreview: dayDataIsPreview,
            readingsPreparationID: routeReadingsPreparationGeneration.currentID,
            normalizedReadings: MapHomeDayCacheReadingsFingerprint(
                readings: normalizedRouteReadings
            ),
            normalizedLastRouteInputSignature:
                MapHomeRouteReadingsPreparation.latestRouteInputSignature(
                    normalizedRouteReadings.last
                ),
            liveReadings: MapHomeDayCacheReadingsFingerprint(
                readings: liveReadings
            ),
            liveLastUpdatedAt: model.liveRouteState.lastUpdatedAt,
            liveLastRouteInputSignature:
                MapHomeRouteReadingsPreparation.latestRouteInputSignature(
                    liveReadings.last
                ),
            latestRouteInputSignature:
                MapHomeRouteReadingsPreparation.latestRouteInputSignature(
                    latestReading
                )
        )
    }

    private func isCurrentExpectedRouteRefresh(
        generation: UInt64,
        inputKey: MapHomeExpectedRouteInputKey
    ) -> Bool {
        !Task.isCancelled
            && scenePhase == .active
            && generation == expectedRouteRefreshGeneration
            && inputKey == currentExpectedRouteInputKey()
    }

    private func refreshExpectedRouteOverlays(generation: UInt64) async {
        guard scenePhase == .active, !Task.isCancelled,
              generation == expectedRouteRefreshGeneration else { return }
        let inputKey = currentExpectedRouteInputKey()
        let selectedDay = inputKey.selectedDay
        let dayEnd = inputKey.dayEnd
        let dayData = currentDayDataSnapshot
        let travel = dayData?.travel ?? []
        let placesCount = (dayData?.places ?? []).count
        let normalizedReadings = normalizedRouteReadings
        let playbackReadings = currentDayReadings
        let day = TimeSpan(start: selectedDay, end: dayEnd)
        let gpsLoggingInterval = model.settings.gpsLoggingPreferences.interval
        let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            var overlayOperationCount = 0
            let overlayRequests = ExpectedRouteRequestEngine.requests(
                travel: travel,
                places: [],
                readings: normalizedReadings,
                in: day,
                through: dayEnd,
                frequentPlaces: [],
                gpsLoggingInterval: gpsLoggingInterval,
                operationCount: &overlayOperationCount
            )
            try Task.checkCancellation()
            var playbackOperationCount = 0
            let playbackRequests = ExpectedRouteRequestEngine.requests(
                travel: travel,
                places: [],
                readings: playbackReadings,
                in: day,
                through: dayEnd,
                frequentPlaces: [],
                gpsLoggingInterval: gpsLoggingInterval,
                operationCount: &playbackOperationCount
            )
            try Task.checkCancellation()
            return MapHomeExpectedRouteRequestBatch(
                overlayRequests: overlayRequests,
                playbackRequests: playbackRequests,
                overlayOperationCount: overlayOperationCount,
                playbackOperationCount: playbackOperationCount,
                readingsWithPointCount: normalizedReadings.reduce(into: 0) {
                    if $1.point != nil { $0 += 1 }
                },
                unconfirmedTravelCount: travel.reduce(into: 0) {
                    if !$1.isConfirmed { $0 += 1 }
                }
            )
        }
        let batch: MapHomeExpectedRouteRequestBatch
        do {
            batch = try await withTaskCancellationHandler(
                operation: { try await worker.value },
                onCancel: { worker.cancel() }
            )
        } catch {
            worker.cancel()
            return
        }
        guard isCurrentExpectedRouteRefresh(
            generation: generation,
            inputKey: inputKey
        ) else { return }
        if wbsExpectedRouteRequests != batch.playbackRequests {
            wbsExpectedRouteRequests = batch.playbackRequests
        }
        if wbsExpectedRouteRequestsInputKey != inputKey {
            wbsExpectedRouteRequestsInputKey = inputKey
        }
        TaptionPlanDiagnosticsLogger.shared.record(
            "expected_route_requests_built",
            fields: expectedRouteRequestDiagnostics(
                requests: batch.overlayRequests,
                travelCount: travel.count,
                unconfirmedTravelCount: batch.unconfirmedTravelCount,
                placesCount: placesCount,
                readingsCount: normalizedReadings.count,
                readingsWithPointCount: batch.readingsWithPointCount,
                dayStart: selectedDay,
                dayEnd: dayEnd,
                operationCount: batch.overlayOperationCount,
                playbackOperationCount: batch.playbackOperationCount
            )
        )
        if expectedRouteCache.count > 128 {
            expectedRouteCache.removeAll(keepingCapacity: true)
        }

        let limitedRequests = Array(
            batch.overlayRequests.prefix(
                MapHomeForecastRouteDisplayPolicy.maximumVisibleRoutes
            )
        )
        // 예상 경로가 모두 캐시에 있으면 직선 임시 경로를 먼저 그리지 않는다. 센서 갱신마다 투영을 두 번 만들고
        // 지도를 두 번 다시 그리던 것이 손짓 중 끊김으로 이어졌다(실사용 기록, PRF1030A02).
        let allExpectedCached = limitedRequests.allSatisfy { (expectedRouteCache[$0]?.count ?? 0) >= 2 }
        if !allExpectedCached {
            let fallbackExpected = limitedRequests.map {
                expectedRouteOverlay(for: $0, coordinates: [
                    CLLocationCoordinate2D(
                        latitude: $0.start.latitude,
                        longitude: $0.start.longitude
                    ),
                    CLLocationCoordinate2D(
                        latitude: $0.end.latitude,
                        longitude: $0.end.longitude
                    ),
                ])
            }
            let fallbackProjection = makeWBSPlaybackProjection(
                expected: fallbackExpected,
                generated: [],
                expectedRouteRequests: batch.playbackRequests
            )
            let excludedLegIDs = Set(
                fallbackExpected.map { "movement-\($0.id.uuidString)" }
                    + storedWBSResolvedRoutes.map(\.legID)
            )
            let fallbackGenerated = Array(
                generatedWBSRouteOverlays(
                    from: fallbackProjection,
                    excluding: excludedLegIDs
                ).prefix(
                    max(
                        0,
                        MapHomeForecastRouteDisplayPolicy.maximumVisibleRoutes
                            - fallbackExpected.count
                    )
                )
            )
            recordExpectedRouteProjectionDiagnostics(
                phase: "fallback",
                projection: fallbackProjection,
                expected: fallbackExpected,
                generated: fallbackGenerated,
                excludedLegIDs: excludedLegIDs
            )
            _ = applyForecastRouteState(
                MapHomeForecastRouteState(
                    expected: fallbackExpected,
                    generated: fallbackGenerated,
                    refreshGeneration: generation,
                    inputKey: inputKey
                )
            )
        }

        var resolvedExpected: [MapHomeExpectedRouteOverlay] = []
        for request in limitedRequests {
            guard isCurrentExpectedRouteRefresh(
                generation: generation,
                inputKey: inputKey
            ) else { return }
            let coordinates: [CLLocationCoordinate2D]
            if let cached = expectedRouteCache[request], cached.count >= 2 {
                coordinates = cached
            } else {
                let resolved = await mapKitRouteCoordinates(for: request)
                guard isCurrentExpectedRouteRefresh(
                    generation: generation,
                    inputKey: inputKey
                ) else { return }
                if resolved.count >= 2 {
                    expectedRouteCache[request] = resolved
                    coordinates = resolved
                } else {
                    coordinates = [
                        CLLocationCoordinate2D(
                            latitude: request.start.latitude,
                            longitude: request.start.longitude
                        ),
                        CLLocationCoordinate2D(
                            latitude: request.end.latitude,
                            longitude: request.end.longitude
                        ),
                    ]
                }
            }
            resolvedExpected.append(
                expectedRouteOverlay(for: request, coordinates: coordinates)
            )
        }
        guard isCurrentExpectedRouteRefresh(
            generation: generation,
            inputKey: inputKey
        ) else { return }

        let resolvedProjection = makeWBSPlaybackProjection(
            expected: resolvedExpected,
            generated: [],
            expectedRouteRequests: batch.playbackRequests
        )
        var resolvedGenerated = Array(
            generatedWBSRouteOverlays(
                from: resolvedProjection,
                excluding: Set(
                    resolvedExpected.map { "movement-\($0.id.uuidString)" }
                        + storedWBSResolvedRoutes.map(\.legID)
                )
            ).prefix(
                max(
                    0,
                    MapHomeForecastRouteDisplayPolicy.maximumVisibleRoutes
                        - resolvedExpected.count
                )
            )
        )
        let resolvedExcludedLegIDs = Set(
            resolvedExpected.map { "movement-\($0.id.uuidString)" }
                + storedWBSResolvedRoutes.map(\.legID)
        )
        recordExpectedRouteProjectionDiagnostics(
            phase: "resolved_before_network_routes",
            projection: resolvedProjection,
            expected: resolvedExpected,
            generated: resolvedGenerated,
            excludedLegIDs: resolvedExcludedLegIDs
        )
        var networkResolvedCount = 0
        for index in resolvedGenerated.indices {
            guard isCurrentExpectedRouteRefresh(
                generation: generation,
                inputKey: inputKey
            ) else { return }
            guard let transport = wbsRouteTransport(for: resolvedGenerated[index].mode),
                  let start = resolvedGenerated[index].coordinates.first,
                  let end = resolvedGenerated[index].coordinates.last else { continue }
            let coordinates = await MapHomeAppleRouteResolver.shared.resolve(
                start: start,
                end: end,
                transport: transport,
                departureDate: resolvedGenerated[index].departureDate
            )
            guard isCurrentExpectedRouteRefresh(
                generation: generation,
                inputKey: inputKey
            ) else { return }
            if let coordinates, coordinates.count >= 2 {
                resolvedGenerated[index] = MapHomeWBSGeneratedRouteOverlay(
                    id: resolvedGenerated[index].id,
                    mode: resolvedGenerated[index].mode,
                    departureDate: resolvedGenerated[index].departureDate,
                    arrivalDate: resolvedGenerated[index].arrivalDate,
                    coordinates: coordinates
                )
                networkResolvedCount += 1
            }
        }
        TaptionPlanDiagnosticsLogger.shared.record(
            "expected_route_network_resolution",
            fields: [
                "generated_requested": String(resolvedGenerated.count),
                "generated_network_resolved": String(networkResolvedCount),
                "generated_network_fallback": String(
                    resolvedGenerated.count - networkResolvedCount
                ),
            ]
        )
        recordExpectedRouteProjectionDiagnostics(
            phase: "resolved_after_network_routes",
            projection: resolvedProjection,
            expected: resolvedExpected,
            generated: resolvedGenerated,
            excludedLegIDs: resolvedExcludedLegIDs
        )
        guard isCurrentExpectedRouteRefresh(
            generation: generation,
            inputKey: inputKey
        ) else { return }
        let didApply = applyForecastRouteState(
            MapHomeForecastRouteState(
                expected: resolvedExpected,
                generated: resolvedGenerated,
                refreshGeneration: generation,
                inputKey: inputKey
            )
        )
        guard didApply else { return }
        applyInitialMapFocusIfNeeded()
        // 현재 위치를 따라가는 중에는 예상 경로가 갱신돼도 "경로 전체 보기"로 카메라를 끌어가지 않는다.
        // 갱신이 끝날 때마다 전체 보기와 현재 위치 따라가기가 번갈아 카메라를 옮겨 화면이 왔다 갔다 했다(대표 영상, ARC1030A02).
        if !userTrackingMode.keepsCameraLocked,
           MapHomePlaybackCameraPolicy.allowsAutomaticFit(
               isPlaybackRunning: isDayPlaybackRunning,
               hasUserAdjustedMap: hasUserAdjustedMap
           ) {
            focusMapOnAllRoutes()
        }
        persistMapDayCache()
    }

    private func expectedRouteOverlay(
        for request: ExpectedRouteRequest,
        coordinates: [CLLocationCoordinate2D]
    ) -> MapHomeExpectedRouteOverlay {
        MapHomeExpectedRouteOverlay(
            id: request.id,
            segmentID: request.segmentID,
            mode: request.mode,
            departureDate: request.departureDate,
            arrivalDate: request.arrivalDate,
            coordinates: coordinates
        )
    }

    private func generatedWBSRouteOverlays(
        from projection: MapHomeWBSPlaybackProjection,
        excluding excludedLegIDs: Set<String>
    ) -> [MapHomeWBSGeneratedRouteOverlay] {
        projection.legs.compactMap { leg in
            guard leg.routePhase == .forecast,
                  leg.activity == .movement,
                  !excludedLegIDs.contains(leg.id),
                  leg.coordinates.count >= 2 else { return nil }
            return MapHomeWBSGeneratedRouteOverlay(
                id: leg.id,
                mode: leg.mode,
                departureDate: leg.startDate,
                arrivalDate: leg.endDate,
                coordinates: leg.coordinates.map {
                    CLLocationCoordinate2D(
                        latitude: $0.latitude,
                        longitude: $0.longitude
                    )
                }
            )
        }
    }

    private func expectedRouteRequestDiagnostics(
        requests: [ExpectedRouteRequest],
        travelCount: Int,
        unconfirmedTravelCount: Int,
        placesCount: Int,
        readingsCount: Int,
        readingsWithPointCount: Int,
        dayStart: Date,
        dayEnd: Date,
        operationCount: Int,
        playbackOperationCount: Int
    ) -> [String: String] {
        let requestModes = Dictionary(grouping: requests, by: \.mode)
        let requestSegmentIDs = Set(requests.map(\.segmentID))
        return [
            "day_start": String(dayStart.timeIntervalSince1970),
            "day_end": String(dayEnd.timeIntervalSince1970),
            "travel_segments": String(travelCount),
            "unconfirmed_travel_segments": String(unconfirmedTravelCount),
            "places": String(placesCount),
            "readings": String(readingsCount),
            "readings_with_point": String(readingsWithPointCount),
            "request_count": String(requests.count),
            "request_unique_segment_count": String(requestSegmentIDs.count),
            "request_duplicate_segment_count": String(
                max(0, requests.count - requestSegmentIDs.count)
            ),
            "request_mode_counts": TravelMode.allCases.compactMap { mode in
                guard let count = requestModes[mode]?.count else { return nil }
                return "\(mode.rawValue)=\(count)"
            }.joined(separator: ","),
            "route_cache_count": String(expectedRouteCache.count),
            "request_operations": String(operationCount),
            "playback_request_operations": String(playbackOperationCount),
        ]
    }

    private func recordExpectedRouteProjectionDiagnostics(
        phase: String,
        projection: MapHomeWBSPlaybackProjection,
        expected: [MapHomeExpectedRouteOverlay],
        generated: [MapHomeWBSGeneratedRouteOverlay],
        excludedLegIDs: Set<String>
    ) {
        let forecastMovements = projection.legs.filter {
            $0.routePhase == .forecast && $0.activity == .movement
        }
        let forecastGapMovements = forecastMovements.filter {
            $0.id.hasPrefix("movement-gap-")
        }
        let forecastTravelMovements = forecastMovements.filter {
            !$0.id.hasPrefix("movement-gap-")
                && $0.id.hasPrefix("movement-")
        }
        let actualMovements = projection.legs.filter {
            $0.routePhase == .actual && $0.activity == .movement
        }
        var intervalOverlapPairs = 0
        var sameEndpointPairs = 0
        if forecastMovements.count > 1 {
            for index in 0..<(forecastMovements.count - 1) {
                for otherIndex in (index + 1)..<forecastMovements.count {
                    let lhs = forecastMovements[index]
                    let rhs = forecastMovements[otherIndex]
                    let lhsSpan = TimeSpan(
                        start: lhs.startDate,
                        end: lhs.endDate
                    )
                    if lhsSpan.intersection(with: TimeSpan(
                        start: rhs.startDate,
                        end: rhs.endDate
                    )) != nil {
                        intervalOverlapPairs += 1
                    }
                    guard let lhsStart = lhs.coordinates.first,
                          let lhsEnd = lhs.coordinates.last,
                          let rhsStart = rhs.coordinates.first,
                          let rhsEnd = rhs.coordinates.last else {
                        continue
                    }
                    let sameDirection = distanceMeters(lhsStart, rhsStart) <= 100
                        && distanceMeters(lhsEnd, rhsEnd) <= 100
                    let reverseDirection = distanceMeters(lhsStart, rhsEnd) <= 100
                        && distanceMeters(lhsEnd, rhsStart) <= 100
                    if sameDirection || reverseDirection {
                        sameEndpointPairs += 1
                    }
                }
            }
        }
        let generatedModes = Dictionary(
            grouping: generated.compactMap(\.mode),
            by: { $0 }
        )
        var routeCandidates: [MapHomeExpectedRouteDiagnostics.Candidate] = []
        for route in expected {
            guard let first = route.coordinates.first, let last = route.coordinates.last else { continue }
            routeCandidates.append(MapHomeExpectedRouteDiagnostics.Candidate(
                kind: "expected", mode: route.mode.rawValue,
                start: route.departureDate, end: route.arrivalDate, first: first, last: last
            ))
        }
        for route in generated {
            guard let first = route.coordinates.first, let last = route.coordinates.last else { continue }
            routeCandidates.append(MapHomeExpectedRouteDiagnostics.Candidate(
                kind: "generated", mode: route.mode?.rawValue ?? "unknown",
                start: route.departureDate, end: route.arrivalDate, first: first, last: last
            ))
        }
        for leg in forecastMovements {
            guard let first = leg.coordinates.first, let last = leg.coordinates.last else { continue }
            let kind: String = leg.id.hasPrefix("movement-gap-") ? "forecast_gap" : "forecast_movement"
            routeCandidates.append(MapHomeExpectedRouteDiagnostics.Candidate(
                kind: kind, mode: "leg",
                start: leg.startDate, end: leg.endDate,
                first: CLLocationCoordinate2D(latitude: first.latitude, longitude: first.longitude),
                last: CLLocationCoordinate2D(latitude: last.latitude, longitude: last.longitude)
            ))
        }
        let routeSummary: [String: String] = MapHomeExpectedRouteDiagnostics.fields(for: routeCandidates)
        let baseFields: [String: String] = [
                "phase": phase,
                "expected_overlay_count": String(expected.count),
                "generated_overlay_count": String(generated.count),
                "projection_leg_count": String(projection.legs.count),
                "projection_forecast_movement_count": String(
                    forecastMovements.count
                ),
                "projection_forecast_travel_movement_count": String(
                    forecastTravelMovements.count
                ),
                "projection_forecast_gap_count": String(
                    forecastGapMovements.count
                ),
                "projection_actual_movement_count": String(
                    actualMovements.count
                ),
                "forecast_interval_overlap_pairs": String(
                    intervalOverlapPairs
                ),
                "forecast_same_endpoint_pairs": String(sameEndpointPairs),
                "excluded_leg_count": String(excludedLegIDs.count),
                "generated_mode_counts": TravelMode.allCases.compactMap {
                    mode in
                    guard let count = generatedModes[mode]?.count else {
                        return nil
                    }
                    return "\(mode.rawValue)=\(count)"
                }.joined(separator: ","),
        ]
        TaptionPlanDiagnosticsLogger.shared.record(
            "expected_route_projection_built",
            fields: baseFields.merging(routeSummary, uniquingKeysWith: { base, _ in base })
        )
    }

    private func wbsRouteTransport(
        for mode: TravelMode?
    ) -> ExpectedRouteTransport? {
        guard let mode else { return nil }
        switch mode {
        case .car, .taxi: return .automobile
        case .bus, .subway, .train: return .transit
        case .walking, .running, .cycling: return .walking
        case .airplane, .ship: return .direct
        }
    }

    @discardableResult
    private func applyForecastRouteState(
        _ state: MapHomeForecastRouteState
    ) -> Bool {
        guard state.refreshGeneration == expectedRouteRefreshGeneration,
              state.inputKey == currentExpectedRouteInputKey() else {
            return false
        }
        guard !isTimelineInteractionActive || isDayPlaybackRunning else {
            pendingForecastRouteState = state
            hasDeferredWBSPlaybackRefresh = true
            TaptionPlanDiagnosticsLogger.shared.record(
                "expected_route_state_deferred",
                fields: [
                    "expected_overlay_count": String(state.expected.count),
                    "generated_overlay_count": String(state.generated.count),
                ]
            )
            return false
        }
        pendingForecastRouteState = nil
        mapRenderCache.invalidateExpectedRoutes()
        expectedRouteOverlays = state.expected
        wbsGeneratedRouteOverlays = state.generated
        refreshWBSPlaybackProjection()
        TaptionPlanDiagnosticsLogger.shared.record(
            "expected_route_state_applied",
            fields: [
                "expected_overlay_count": String(state.expected.count),
                "generated_overlay_count": String(state.generated.count),
            ]
        )
        return true
    }

    private func mapKitRouteCoordinates(
        for routeRequest: ExpectedRouteRequest
    ) async -> [CLLocationCoordinate2D] {
        await MapHomeAppleRouteResolver.shared.resolve(
            start: CLLocationCoordinate2D(
                latitude: routeRequest.start.latitude,
                longitude: routeRequest.start.longitude
            ),
            end: CLLocationCoordinate2D(
                latitude: routeRequest.end.latitude,
                longitude: routeRequest.end.longitude
            ),
            transport: routeRequest.transport,
            departureDate: routeRequest.departureDate
        ) ?? []
    }

    private var subwayRouteOverlays: [MapHomeSubwayRouteOverlay] {
        let probe = MapHomePlaybackProbe.begin("subwayOverlays"); defer { MapHomePlaybackProbe.end(probe) }
        let dayData = currentDayDataSnapshot
        let calendar = Calendar.autoupdatingCurrent
        guard let dayStart = calendar.startOfDay(for: model.selectedDate) as Date?,
              let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)
        else { return [] }
        let day = TimeSpan(start: dayStart, end: dayEnd)
        let cutoff = routeOverlayCutoff
        let cutoffMinute = calendar.dateComponents(
            [.minute],
            from: dayStart,
            to: cutoff
        ).minute ?? effectiveTimelineMinute
        // 분이 바뀔 때마다 지하철 구간을 다시 풀면 재생이 100ms씩 멈췄다. 같은 날·같은 기록이면 이전 값을 먼저 보여 주고
        // 새 분의 값은 뒤에서 만든다(ARC1030A01).
        let travel = dayData?.travel ?? []
        let stored = routeReadings
        let live = model.liveRouteState.readings
        let latest = model.latestSensorReading
        subwayOverlayDerived.onUpdate = { [mapRenderCache] in
            mapRenderCache.invalidateRouteBounds()
            // 재생 중에는 0.25초마다 오는 분 알림이 화면을 다시 그린다. 재생이 아닐 때만 직접 깨운다.
            if !isDayPlaybackRunning { derivedUpdateTick &+= 1 }
        }
        return subwayOverlayDerived.value(
            group: readingsSignature(sourceRevision: dayData?.sourceRevision),
            step: cutoffMinute
        ) {
            MapHomeSubwayRouteOverlayEngine.overlays(
                travel: travel,
                readings: stored + live + (latest.map { [$0] } ?? []),
                day: day,
                through: cutoff
            )
        }
    }

    /// 센서 기록 묶음의 변경 표지. 개수·마지막 번호만 봐서 값 비교가 O(1)이다.
    private func readingsSignature(sourceRevision: UInt64?) -> MapHomeReadingsSignature {
        MapHomeReadingsSignature(
            day: Calendar.autoupdatingCurrent.startOfDay(for: model.selectedDate),
            sourceRevision: sourceRevision,
            storedCount: routeReadings.count, storedLastID: routeReadings.last?.id,
            liveCount: model.liveRouteState.readings.count, liveLastID: model.liveRouteState.readings.last?.id,
            latestID: model.latestSensorReading?.id
        )
    }

    private var temporaryLocationAnnotations: [MapHomeTemporaryLocationAnnotation] {
        let probe = MapHomePlaybackProbe.begin("temporaryLocations"); defer { MapHomePlaybackProbe.end(probe) }
        // 임시 위치는 하루 기록만으로 정해지고 컷오프와 무관하다(컷오프는 아래에서 거른다). 매번 다시 뽑지 않는다(ARC1030A01).
        let derived = temporaryLocationsMemo.value(for: readingsSignature(sourceRevision: currentDayDataSnapshot?.sourceRevision)) {
            SubwayStationCatalog.temporaryLocations(
                from: routeReadings + model.liveRouteState.readings + (model.latestSensorReading.map { [$0] } ?? [])
            )
        }
        let locations = derived.isEmpty ? cachedTemporaryLocations : derived
        return locations
            .filter { $0.timestamp <= routeOverlayCutoff }
            .map {
                MapHomeTemporaryLocationAnnotation(
                    id: $0.id,
                    stationName: $0.stationName,
                    timestamp: $0.timestamp,
                    point: $0.point,
                    reason: $0.reason
                )
            }
    }

    private func makeTimelineRouteOverlays(
        _ projection: RouteTimelineProjection
    ) -> [MapHomeTimelineRouteOverlay] {
        projection.segments.compactMap { segment in
            guard segment.confirmedSubwayTravelID == nil else { return nil }
            let coordinates = segment.coordinates.compactMap { point -> CLLocationCoordinate2D? in
                guard isValid(point) else { return nil }
                return CLLocationCoordinate2D(
                    latitude: point.latitude,
                    longitude: point.longitude
                )
            }
            guard coordinates.count >= 2 else { return nil }
            return MapHomeTimelineRouteOverlay(
                id: segment.id,
                categoryID: segment.category.rawValue,
                opacity: segment.opacity,
                speedMetersPerSecond: segment.speedMetersPerSecond,
                coordinates: coordinates,
                coordinateTimestamps: segment.coordinateTimestamps
            )
        }
    }

    private var wbsPlaybackFrame: MapHomeWBSPlaybackFrame? {
        let probe = MapHomePlaybackProbe.begin("wbsFrame"); defer { MapHomePlaybackProbe.end(probe) }
        guard selectedTimelineMinute != nil else { return nil }
        return wbsPlaybackProjection?.frame(
            at: displayedLocationDate,
            preferredForecastLegIDs: visibleForecastPlaybackLegIDs
        )
    }

    private var visibleForecastPlaybackLegIDs: Set<String> {
        Set(
            displayedExpectedRouteOverlays.map {
                "movement-\($0.id.uuidString)"
            } + displayedWBSGeneratedRouteOverlays.map(\.id)
        )
    }

    private var historicalPlaybackCoordinate: CLLocationCoordinate2D? {
        guard let point = displayedPlaybackLocation?.coordinate,
              isValid(point) else { return nil }
        return CLLocationCoordinate2D(
            latitude: point.latitude,
            longitude: point.longitude
        )
    }

    private var activeExpectedRoute: MapHomeExpectedRouteOverlay? {
        let date = displayedLocationDate
        let visibleIDs = Set(displayedExpectedRouteOverlays.map(\.id))
        return expectedRouteOverlays
            .filter {
                visibleIDs.contains($0.id)
                    && $0.coordinates.count >= 2
                    && $0.departureDate <= date
                    && date <= $0.arrivalDate
            }
            .min { $0.departureDate < $1.departureDate }
    }

    private var expectedRoutePlaybackCoordinate: CLLocationCoordinate2D? {
        activeExpectedRoute?.coordinate(at: displayedLocationDate)
    }

    private var displayedPlaybackFocusPoint: GeoPoint? {
        displayedPlaybackLocation?.cameraCoordinate
    }

    private var displayedPlaybackLocation: MapHomePlaybackLocation? {
        guard selectedTimelineMinute != nil else { return nil }
        if let point = selectedPawprintPoint {
            return MapHomePlaybackLocation(coordinate: point)
        }
        let frame = wbsPlaybackFrame
        let expectedPoint = frame == nil ? expectedRoutePlaybackCoordinate.flatMap { coordinate in
            CLLocationCoordinate2DIsValid(coordinate) ? wbsGeoPoint(coordinate) : nil
        } : nil
        return MapHomePlaybackLocation.resolveOrGap(
            at: displayedLocationDate,
            frame: frame,
            normalizedReadings: routeReadingsLoadState.isLoaded(for: model.selectedDate)
                ? historicalPlaybackReadings : [],
            travel: currentDayDataSnapshot?.travel ?? [],
            places: currentDayDataSnapshot?.places ?? [],
            expectedCoordinate: expectedPoint
        )
    }

    private var displayedLocationCoordinate: CLLocationCoordinate2D? {
        let isToday = Calendar.autoupdatingCurrent.isDateInToday(model.selectedDate)
        // GPS가 끊겨도 오늘은 화랑이를 마지막 위치에 둔다.
        if selectedTimelineMinute != nil { return historicalPlaybackCoordinate ?? (isToday ? lastKnownCoordinate : nil) }
        return isToday ? liveFocusCoordinate : nil
    }

    private var displayedPlaybackMinute: Double? {
        guard selectedTimelineMinute != nil else { return nil }
        if isDayPlaybackRunning {
            return dayPlaybackCurrentMinute
                ?? Double(selectedTimelineMinute ?? effectiveTimelineMinute)
        }
        if let selection = MapHomePawprintInteractionPolicy.selection(
            timestamp: selectedPawprintTimestamp, isPredicted: false,
            selectedDate: model.selectedDate
        ), selection.minute == selectedTimelineMinute {
            return selection.minuteOffset
        }
        return Double(selectedTimelineMinute ?? effectiveTimelineMinute)
    }

    private var selectedPawprintPoint: GeoPoint? {
        guard !isDayPlaybackRunning,
              let coordinate = selectedPawprintCoordinate,
              let selection = MapHomePawprintInteractionPolicy.selection(
                timestamp: selectedPawprintTimestamp, isPredicted: false,
                selectedDate: model.selectedDate
              ), selection.minute == selectedTimelineMinute else { return nil }
        return wbsGeoPoint(coordinate)
    }

    private var displayedPlaybackDate: Date? {
        displayedPlaybackMinute.map(timelineDate(forMinute:))
    }

    private var displayedLocationDate: Date {
        if let displayedPlaybackDate {
            return displayedPlaybackDate
        }
        let calendar = Calendar.autoupdatingCurrent
        return calendar.isDateInToday(model.selectedDate)
            ? MapHomeTransitBoardingRefreshPolicy.cutoffBucket(.now)
            : calendar.startOfDay(for: model.selectedDate)
    }

    /// 마커 고양이가 속도 구간을 표현할 수 있도록 현재 표시 지점의 속도를
    /// m/s로 추정한다. 재생 중이면 현재 leg의 이동 세그먼트 속도(거리/시간),
    /// 실시간이면 최신 센서 속도를 쓴다. 정지/미확정이면 nil.
    private var displayedSpeedMetersPerSecond: Double? {
        if selectedTimelineMinute != nil {
            return MapHomePlaybackSpeed.speed(
                at: displayedLocationDate,
                travel: currentDayDataSnapshot?.travel ?? [],
                readings: historicalPlaybackReadings
            )
        }
        return model.latestSensorReading?.speedMetersPerSecond
    }

    /// 화랑이 동작. 한 화면을 그리는 동안 여러 번 불리고, 마지막 분기는 하루 기록 전체를 이어 붙여 복사한다. 입력이 같으면(초 단위)
    /// 이전 값을 쓴다(재생 중 3천 번 넘게 불렸다, ARC1030A01).
    private var displayedStickmanAction: MapHomeStickmanAction {
        let probe = MapHomePlaybackProbe.begin("stickmanAction"); defer { MapHomePlaybackProbe.end(probe) }
        let key = MapHomeStickmanActionKey(
            second: Int(displayedLocationDate.timeIntervalSinceReferenceDate),
            sourceRevision: currentDayDataSnapshot?.sourceRevision,
            sleepCount: model.sleepSessions.count,
            frequentPlaceCount: model.settings.frequentPlaces.count,
            legCount: wbsPlaybackProjection?.legs.count ?? 0,
            expectedCount: expectedRouteOverlays.count,
            latestID: model.latestSensorReading?.id,
            hasSelection: selectedTimelineMinute != nil
        )
        return stickmanActionMemo.value(for: key) { computeDisplayedStickmanAction() }
    }

    private func computeDisplayedStickmanAction() -> MapHomeStickmanAction {
        let actuals = currentDayDataSnapshot?.actuals ?? []
        let sleepSessions = model.sleepSessions
        if MapHomeStickmanActionResolver.hasAppleWatchConfirmedSleep(
            at: displayedLocationDate,
            actuals: actuals,
            sleepSessions: sleepSessions
        ) {
            return MapHomeStickmanActionResolver.sleepStageAction(at: displayedLocationDate, actuals: actuals, sleepSessions: sleepSessions)
        }
        if let frame = wbsPlaybackFrame {
            switch frame.activity {
            case .movement:
                let mode = frame.mode ?? MapHomePlaybackLocation.gapMode(at: displayedLocationDate, travel: currentDayDataSnapshot?.travel ?? [], readings: historicalPlaybackReadings)
                return mode.map(MapHomeStickmanActionResolver.action(for:)) ?? .movement
            case .stay:
                if let categoryID = frame.categoryID {
                    return MapHomeStickmanActionResolver.action(
                        for: categoryID,
                        label: ""
                    )
                }
            }
        }
        if selectedTimelineMinute != nil, activeExpectedRoute == nil || currentDayDataSnapshot?.travel.contains(where: { $0.span.contains(displayedLocationDate) }) == true, let mode = MapHomePlaybackLocation.gapMode(at: displayedLocationDate, travel: currentDayDataSnapshot?.travel ?? [], readings: historicalPlaybackReadings) {
            return MapHomeStickmanActionResolver.action(for: mode)
        }
        if let activeExpectedRoute {
            return MapHomeStickmanActionResolver.action(for: activeExpectedRoute.mode)
        }
        let resolved = MapHomeStickmanActionResolver.action(
            at: displayedLocationDate,
            actuals: actuals,
            travel: currentDayDataSnapshot?.travel ?? [],
            places: currentDayDataSnapshot?.places ?? [],
            frequentPlaces: model.settings.frequentPlaces,
            readings: (currentDayDataSnapshot?.readings ?? routeReadings)
                + model.liveRouteState.readings
                + (model.latestSensorReading.map { [$0] } ?? []),
            sleepSessions: sleepSessions
        )
        guard resolved == .activity, selectedTimelineMinute == nil else { return resolved }
        return MapHomeStickmanActionResolver.action(atCurrent: model.latestSensorReading?.point, frequentPlaces: model.settings.frequentPlaces) ?? resolved
    }

    private var displayedLocationAccessibilityLabel: String {
        if wbsPlaybackFrame?.routePhase == .forecast
            || expectedRoutePlaybackCoordinate != nil {
            return language.text("예상 경로 위치", "Expected route location")
        }
        return historicalPlaybackCoordinate == nil
            ? language.text("현재 위치", "Current location")
            : historicalPlaybackAccessibilityLabel
    }

    private var historicalPlaybackAccessibilityLabel: String {
        let minute = min(
            max(Int((displayedPlaybackMinute ?? 0).rounded(.down)), 0),
            MapHomeTimeSidebarMath.fullDayMinutes
        )
        let time = String(format: "%02d:%02d", minute / 60, minute % 60)
        return language.text("과거 위치 \(time)", "Past location \(time)")
    }

    private var effectiveTimelineMinute: Int {
        timelineSelectionMinute()
    }

    /// 과거 날짜 기본값 1440분은 다음 날 0시가 되므로 저장·일정 판정용 시각은 그날 23:59로 묶는다.
    private var timelineSelectionDate: Date {
        timelineDate(forMinute: Double(min(
            effectiveTimelineMinute,
            MapHomeTimeSidebarMath.fullDayMinutes - 1
        )))
    }

    private func timelineDate(forMinute minute: Double) -> Date {
        let safeMinute = minute.isFinite
            ? min(
                Double(MapHomeTimeSidebarMath.fullDayMinutes),
                max(0, minute)
            )
            : 0
        let wholeMinute = min(
            MapHomeTimeSidebarMath.fullDayMinutes,
            Int(safeMinute.rounded(.down))
        )
        let fraction = safeMinute - Double(wholeMinute)
        let date = RouteTimelineDataEngine.timelineDate(
            selectedDate: model.selectedDate,
            minute: wholeMinute
        ).addingTimeInterval(fraction * 60)
        return clampedTimelineDate(date)
    }

    private var routeTimelineDate: Date {
        displayedPlaybackDate
            ?? clampedTimelineDate(
                RouteTimelineDataEngine.timelineDate(
                    selectedDate: model.selectedDate,
                    minute: effectiveTimelineMinute
                )
            )
    }

    private func timelineSelectionMinute(
        at now: Date = .now
    ) -> Int {
        if isTimelineSelectionPinned, let selectedTimelineMinute {
            return selectedTimelineMinute
        }
        return selectedTimelineMinute ?? MapHomeTimeSidebarMath.defaultTimelineMinute(
            for: model.selectedDate,
            now: now,
            calendar: .autoupdatingCurrent
        )
    }

    private var timelineSelectionSpan: TimeSpan? {
        let calendar = Calendar.autoupdatingCurrent
        let dayStart = calendar.startOfDay(for: model.selectedDate)
        guard let segment = MapHomeTimeRailSegmentEngine.segment(
            at: effectiveTimelineMinute,
            in: timeRailSegments
        ), let end = calendar.date(
            byAdding: .minute,
            value: segment.endMinute,
            to: dayStart
        ), let start = calendar.date(
            byAdding: .minute,
            value: segment.startMinute,
            to: dayStart
        ) else { return nil }
        return TimeSpan(start: start, end: end)
    }

    /// 하루 전체의 상세 활동. 구간 경계에서 자르지 않으므로 경계에 걸친 기록도 온전히 남는다.
    private func allDaySectionDetails() -> [MapHomeSectionDetail] {
        let calendar = Calendar.autoupdatingCurrent
        let dayStart = calendar.startOfDay(for: model.selectedDate)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return [] }
        let dayData = currentDayDataSnapshot
        return MapHomeSectionDetailEngine.dayDetails(
            actuals: dayData?.actuals ?? [],
            travel: dayData?.travel ?? [],
            dayStart: dayStart,
            dayEnd: dayEnd,
            asOf: .now
        )
    }

    private func sectionDetails(at minute: Int) -> [MapHomeSectionDetail] {
        let calendar = Calendar.autoupdatingCurrent
        let dayData = currentDayDataSnapshot
        let dayStart = calendar.startOfDay(for: model.selectedDate)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart),
              let segment = MapHomeTimeRailSegmentEngine.segment(
                at: minute,
                in: timeRailSegments
              )
        else { return [] }
        return MapHomeSectionDetailEngine.details(
            actuals: dayData?.actuals ?? [],
            travel: dayData?.travel ?? [],
            segment: segment,
            dayStart: dayStart,
            dayEnd: dayEnd,
            asOf: .now
        )
    }

    private func refreshRouteReadings(
        for date: Date,
        forceReload: Bool = false,
        preloadedDayData: PlanDayDataSnapshot? = nil,
        cachedMapDay: MapHomeDayCachePayload? = nil,
        isPreview: Bool = false
    ) async {
        let viewSignpostID = OSSignpostID(log: Self.dayViewSignpostLog)
        os_signpost(
            .begin,
            log: Self.dayViewSignpostLog,
            name: "day_view",
            signpostID: viewSignpostID
        )
        defer {
            os_signpost(
                .end,
                log: Self.dayViewSignpostLog,
                name: "day_view",
                signpostID: viewSignpostID
            )
        }
        let calendar = Calendar.autoupdatingCurrent
        let dayStart = calendar.startOfDay(for: date)
        let dataGeneration = TaptionDataDeletionFence.currentGeneration()
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)
        else { return }
        var dayData: PlanDayDataSnapshot
        var showsCachedPreview = isPreview
        if let preloadedDayData, !forceReload {
            dayData = preloadedDayData
        } else {
            dayData = await model.planDayDataSnapshot(
                for: date,
                forceReload: forceReload
            )
        }
        guard !Task.isCancelled,
              TaptionDataDeletionFence.allows(generation: dataGeneration),
              calendar.isDate(date, inSameDayAs: model.selectedDate)
        else { return }
        if dayData.sourceRevision != model.dayProjectionRevision, model.isBootstrapped {
            guard let rebased = await model.rebasePlanDayDataSnapshot(
                from: dayData,
                for: date
            ) else { return }
            guard !Task.isCancelled,
                  TaptionDataDeletionFence.allows(generation: dataGeneration),
                  calendar.isDate(date, inSameDayAs: model.selectedDate)
            else { return }
            dayData = rebased
        }
        if !isPreview, !dayData.isComplete {
            let previous = dayDataSnapshot?.isComplete == true
                ? dayDataSnapshot
                : await model.cachedPlanDayDataSnapshot(for: date)
            guard !Task.isCancelled,
                  TaptionDataDeletionFence.allows(generation: dataGeneration),
                  calendar.isDate(date, inSameDayAs: model.selectedDate) else { return }
            if let previous, previous.isComplete,
               calendar.isDate(previous.day, inSameDayAs: date) {
                if previous.sourceRevision != model.dayProjectionRevision {
                    guard let rebased = await model.rebasePlanDayDataSnapshot(from: previous, for: date),
                          !Task.isCancelled,
                          TaptionDataDeletionFence.allows(generation: dataGeneration),
                          calendar.isDate(date, inSameDayAs: model.selectedDate) else { return }
                    dayData = rebased
                } else {
                    dayData = previous
                }
                showsCachedPreview = true
                TaptionPlanDiagnosticsLogger.shared.record("map_incomplete_reload_kept_preview",
                    fields: ["readings": String(previous.readings.count)])
            }
        }
        var snapshotFields = TaptionPlanDiagnosticsTravelSummary.fields(
            for: dayData.travel
        )
        snapshotFields["day_start"] = String(dayStart.timeIntervalSince1970)
        snapshotFields["source_revision"] = String(dayData.sourceRevision)
        snapshotFields["projection_version"] = String(dayData.projectionVersion)
        snapshotFields["source_updated_at"] = String(
            dayData.sourceUpdatedAt.timeIntervalSince1970
        )
        snapshotFields["is_complete"] = String(dayData.isComplete)
        snapshotFields["is_preview"] = String(showsCachedPreview)
        snapshotFields["readings"] = String(dayData.readings.count)
        snapshotFields["readings_with_point"] = String(
            dayData.readings.filter { $0.point != nil }.count
        )
        snapshotFields["places"] = String(dayData.places.count)
        snapshotFields["travel"] = String(dayData.travel.count)
        TaptionPlanDiagnosticsLogger.shared.record(
            "map_day_snapshot_loaded",
            fields: snapshotFields
        )
        dayDataSnapshot = dayData
        reportInitialMapShellReadyIfNeeded(for: model.selectedDate)
        routeActualIndex = nil
        dayDataIsPreview = showsCachedPreview
        let merged = MapHomeRouteReadingsPolicy.merging(
            existing: routeReadings,
            loaded: dayData.readings,
            in: TimeSpan(start: dayStart, end: dayEnd)
        )
        routeReadingsLoadState = isPreview ? .loading(dayStart) : dayData.isComplete
            ? .loaded(dayStart)
            : .failed(dayStart)
        if merged != routeReadings {
            routeReadings = merged
            transitBoardingReadingsRevision &+= 1
        }
        if showsCachedPreview {
            refreshTimeRailSegments()
            prepareRouteProjectionReadings()
            refreshRouteProjection()
            focusMapIfNeeded()
            return
        }
        let restoredCachedRoutes = cachedMapDay.map {
            applyMapDayCacheRoutes($0, for: date, dayData: dayData)
        } ?? false
        refreshTimeRailSegments()
        scheduleTransitPOIRefresh()
        scheduleExpectedRouteRefresh()
        guard !isTimelineInteractionActive || isDayPlaybackRunning else {
            routeDocumentProjectionGate.deferRefresh(preparingReadings: true)
            return
        }
        if restoredCachedRoutes,
           selectedTimelineMinute == nil,
           !isDayPlaybackRunning {
            focusMapIfNeeded()
            return
        }
        prepareRouteProjectionReadings()
        refreshRouteProjection()
        if selectedTimelineMinute != nil {
            recordCurrentPlaybackAlignment()
            if let point = displayedPlaybackFocusPoint {
                focusMap(
                    on: point,
                    followsTracking: true
                )
            }
        } else {
            focusMapIfNeeded()
        }
        persistMapDayCache()
    }

    private func scheduleTransitPOIRefresh() {
        guard MapHomeTransitPOIRefreshPolicy.canStart(
            isBootstrapped: model.isBootstrapped,
            isSceneActive: scenePhase == .active
        ) else { return }
        let dataGeneration = TaptionDataDeletionFence.currentGeneration()
        guard TaptionDataDeletionFence.allows(
            generation: dataGeneration
        ) else { return }
        let selectedDate = model.selectedDate
        let readings = transitBoardingReadings
        transitPOIRefreshTask?.cancel()
        transitPOIRefreshGeneration &+= 1
        let generation = transitPOIRefreshGeneration
        transitPOIRefreshTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 300_000_000)
            } catch {
                return
            }
            let places = await AppleTransitBoardingPOIResolver.shared.resolving(
                readings: readings
            )
            guard !Task.isCancelled,
                  generation == transitPOIRefreshGeneration,
                  scenePhase == .active,
                  TaptionDataDeletionFence.allows(
                    generation: dataGeneration
                  ),
                  Calendar.autoupdatingCurrent.isDate(
                      selectedDate,
                      inSameDayAs: model.selectedDate
                  ) else { return }
            if nearbyTransitPlaces != places {
                nearbyTransitPlaces = places
                nearbyTransitPlacesRevision &+= 1
            }
        }
    }

    private func loadMapDayCache(
        for date: Date
    ) async -> MapHomeDayCachePayload? {
        let generation = TaptionDataDeletionFence.currentGeneration()
        guard TaptionDataDeletionFence.allows(generation: generation) else {
            return nil
        }
        let styleKey = MapDisplayStyle.mapLibreRPG.runtimeStyle.rawValue
        guard let payload = MapHomeDayCacheMemory.payload(
            day: TaptionPlanDayKey(date: date),
            algorithmKey: Self.mapCacheAlgorithmKey,
            styleKey: styleKey,
            generation: generation
        ), Calendar.autoupdatingCurrent.isDate(date, inSameDayAs: model.selectedDate)
            && TaptionDataDeletionFence.allows(generation: generation)
        else { return nil }
        guard payload.centerLatitude.isFinite,
              payload.centerLongitude.isFinite,
              (-90...90).contains(payload.centerLatitude),
              (-180...180).contains(payload.centerLongitude),
              payload.latitudeDelta.isFinite,
              payload.longitudeDelta.isFinite else { return nil }
        return payload
    }

    private func applyMapDayCacheRoutes(
        _ payload: MapHomeDayCachePayload,
        for date: Date,
        dayData: PlanDayDataSnapshot
    ) -> Bool {
        // Route cache is only a display accelerator. Never publish it before
        // the current raw-backed day snapshot has been validated.
        guard dayData.isComplete,
              let sourceFingerprint = dayData.sourceFingerprint,
              payload.sourceFingerprint == sourceFingerprint,
              payload.readingsFingerprint
                == MapHomeDayCacheReadingsFingerprint(
                    readings: dayData.readings
                ) else {
            TaptionPlanDiagnosticsLogger.shared.record(
                "map_day_cache_rejected",
                fields: ["reason": "day_content_mismatch"]
            )
            return false
        }
        timelineRouteOverlays = payload.timeline.compactMap { overlay in
            let coordinates = overlay.coordinates.compactMap { coordinate -> CLLocationCoordinate2D? in
                guard coordinate.latitude.isFinite,
                      coordinate.longitude.isFinite,
                      (-90...90).contains(coordinate.latitude),
                      (-180...180).contains(coordinate.longitude) else { return nil }
                return CLLocationCoordinate2D(
                    latitude: coordinate.latitude,
                    longitude: coordinate.longitude
                )
            }
            guard coordinates.count >= 2,
                  coordinates.count == overlay.coordinateTimestamps.count,
                  overlay.coordinateTimestamps.allSatisfy(RouteTimelineTimestamp.isValid)
            else { return nil }
            return MapHomeTimelineRouteOverlay(
                id: overlay.id,
                categoryID: overlay.categoryID,
                opacity: overlay.opacity,
                speedMetersPerSecond: overlay.speedMetersPerSecond,
                coordinates: coordinates,
                coordinateTimestamps: overlay.coordinateTimestamps
            )
        }
        cachedTemporaryLocations = (payload.temporaryLocations ?? []).compactMap { item in
            guard item.latitude.isFinite, item.longitude.isFinite,
                  (-90...90).contains(item.latitude), (-180...180).contains(item.longitude)
            else { return nil }
            return SubwayStationCatalog.TemporaryLocation(
                id: item.id, timestamp: item.timestamp, stationName: item.stationName,
                point: GeoPoint(
                    latitude: item.latitude, longitude: item.longitude,
                    altitude: .nan, horizontalAccuracy: .nan, verticalAccuracy: .nan
                ), reason: item.reason
            )
        }
        expectedRouteOverlays = (payload.expected ?? []).compactMap { overlay in
            guard let mode = TravelMode(rawValue: overlay.modeRawValue)
            else { return nil }
            let coordinates = overlay.coordinates.compactMap {
                cachedCoordinate($0)
            }
            guard coordinates.count >= 2 else { return nil }
            return MapHomeExpectedRouteOverlay(
                id: overlay.id,
                segmentID: overlay.segmentID,
                mode: mode,
                departureDate: overlay.departureDate,
                arrivalDate: overlay.arrivalDate,
                coordinates: coordinates
            )
        }
        mapRenderCache.invalidateExpectedRoutes()
        requestWBSPlaybackProjectionRefresh()
        if let subwayMinute = payload.subwayMinute {
            let overlays: [MapHomeSubwayRouteOverlay] =
                (payload.subway ?? []).compactMap { overlay in
                let coordinates = overlay.coordinates.compactMap {
                    cachedCoordinate($0)
                }
                guard !overlay.estimated, coordinates.count >= 2 else {
                    return nil
                }
                return MapHomeSubwayRouteOverlay(
                    id: overlay.id,
                    coordinates: coordinates,
                    estimated: overlay.estimated,
                    travelID: overlay.travelID
                )
            }
            mapRenderCache.restoreSubwayRoutes(
                day: Calendar.autoupdatingCurrent.startOfDay(for: date),
                minute: subwayMinute,
                overlays: overlays
            )
        }
        TaptionPlanDiagnosticsLogger.shared.record(
            "map_day_cache_restored",
            fields: [
                "day_start": String(
                    Calendar.autoupdatingCurrent.startOfDay(
                        for: date
                    ).timeIntervalSince1970
                ),
                "timeline_overlay_count": String(timelineRouteOverlays.count),
                "expected_overlay_count": String(expectedRouteOverlays.count),
                "temporary_location_count": String(cachedTemporaryLocations.count),
                "subway_overlay_count": String((payload.subway ?? []).count),
                "source_updated_at": payload.sourceUpdatedAt.map {
                    String($0.timeIntervalSince1970)
                } ?? "none",
            ]
        )
        return true
    }

    private func cachedCoordinate(
        _ coordinate: MapHomeCachedCoordinate
    ) -> CLLocationCoordinate2D? {
        guard coordinate.latitude.isFinite,
              coordinate.longitude.isFinite,
              (-90...90).contains(coordinate.latitude),
              (-180...180).contains(coordinate.longitude) else { return nil }
        return CLLocationCoordinate2D(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        )
    }

    private func persistMapDayCache() {
        guard let dayData = currentDayDataSnapshot,
              dayData.isComplete,
              visibleMapCenter.latitude.isFinite,
              visibleMapCenter.longitude.isFinite,
              visibleMapSpan.latitudeDelta.isFinite,
              visibleMapSpan.longitudeDelta.isFinite else { return }
        let generation = TaptionDataDeletionFence.currentGeneration()
        guard TaptionDataDeletionFence.allows(generation: generation) else {
            return
        }
        let calendar = Calendar.autoupdatingCurrent
        let dayStart = calendar.startOfDay(for: model.selectedDate)
        let subwayMinute = calendar.dateComponents(
            [.minute],
            from: dayStart,
            to: routeOverlayCutoff
        ).minute ?? effectiveTimelineMinute
        let readingsFingerprint = MapHomeDayCacheReadingsFingerprint(
            readings: dayData.readings
        )
        let styleKey = MapDisplayStyle.mapLibreRPG.runtimeStyle.rawValue
        var signature = Hasher()
        signature.combine(generation)
        signature.combine(dayStart.timeIntervalSinceReferenceDate.bitPattern)
        signature.combine(dayData.sourceFingerprint)
        signature.combine(readingsFingerprint.count)
        signature.combine(readingsFingerprint.firstID)
        signature.combine(readingsFingerprint.lastID)
        signature.combine(
            readingsFingerprint.firstTimestamp?
                .timeIntervalSinceReferenceDate.bitPattern
        )
        signature.combine(
            readingsFingerprint.lastTimestamp?
                .timeIntervalSinceReferenceDate.bitPattern
        )
        signature.combine(visibleMapCenter.latitude.bitPattern)
        signature.combine(visibleMapCenter.longitude.bitPattern)
        signature.combine(visibleMapSpan.latitudeDelta.bitPattern)
        signature.combine(visibleMapSpan.longitudeDelta.bitPattern)
        signature.combine(styleKey)
        signature.combine(subwayMinute)
        for overlay in timelineRouteOverlays {
            signature.combine(overlay.id)
            signature.combine(overlay.geometrySignature)
            signature.combine(overlay.categoryID)
            signature.combine(overlay.opacity.bitPattern)
            signature.combine(overlay.speedMetersPerSecond?.bitPattern)
        }
        for overlay in expectedRouteOverlays {
            signature.combine(overlay.id)
            signature.combine(overlay.geometrySignature)
            signature.combine(overlay.mode.rawValue)
            signature.combine(
                overlay.departureDate.timeIntervalSinceReferenceDate.bitPattern
            )
            signature.combine(
                overlay.arrivalDate.timeIntervalSinceReferenceDate.bitPattern
            )
        }
        for overlay in subwayRouteOverlays {
            signature.combine(overlay.id)
            signature.combine(overlay.geometrySignature)
            signature.combine(overlay.estimated)
        }
        for location in temporaryLocationAnnotations {
            signature.combine(location.id)
            signature.combine(
                location.timestamp.timeIntervalSinceReferenceDate.bitPattern
            )
            signature.combine(location.stationName)
            signature.combine(location.point.latitude.bitPattern)
            signature.combine(location.point.longitude.bitPattern)
            signature.combine(location.reason)
        }
        let writeSignature = signature.finalize()
        guard writeSignature != mapDayCacheWriteSignature else { return }
        mapDayCacheWriteSignature = writeSignature
        let cachedSubwayRoutes = subwayRouteOverlays
        let payload = MapHomeDayCachePayload(
            sourceUpdatedAt: dayData.sourceUpdatedAt,
            sourceRevision: dayData.sourceRevision,
            sourceFingerprint: dayData.sourceFingerprint,
            readingsFingerprint: readingsFingerprint,
            centerLatitude: visibleMapCenter.latitude,
            centerLongitude: visibleMapCenter.longitude,
            latitudeDelta: visibleMapSpan.latitudeDelta,
            longitudeDelta: visibleMapSpan.longitudeDelta,
            timeline: timelineRouteOverlays.map { overlay in
                MapHomeCachedRouteOverlay(
                    id: overlay.id,
                    categoryID: overlay.categoryID,
                    opacity: overlay.opacity,
                    speedMetersPerSecond: overlay.speedMetersPerSecond,
                    coordinates: overlay.coordinates.map {
                        MapHomeCachedCoordinate(
                            latitude: $0.latitude,
                            longitude: $0.longitude
                        )
                    },
                    coordinateTimestamps: overlay.coordinateTimestamps
                )
            },
            expected: expectedRouteOverlays.map { overlay in
                MapHomeCachedExpectedRouteOverlay(
                    id: overlay.id,
                    segmentID: overlay.segmentID,
                    modeRawValue: overlay.mode.rawValue,
                    departureDate: overlay.departureDate,
                    arrivalDate: overlay.arrivalDate,
                    coordinates: overlay.coordinates.map {
                        MapHomeCachedCoordinate(
                            latitude: $0.latitude,
                            longitude: $0.longitude
                        )
                    }
                )
            },
            subway: cachedSubwayRoutes.map { overlay in
                MapHomeCachedSubwayRouteOverlay(
                    id: overlay.id,
                    estimated: overlay.estimated,
                    coordinates: overlay.coordinates.map {
                        MapHomeCachedCoordinate(
                            latitude: $0.latitude,
                            longitude: $0.longitude
                        )
                    },
                    travelID: overlay.travelID
                )
            },
            subwayMinute: subwayMinute,
            temporaryLocations: temporaryLocationAnnotations.map { location in
                MapHomeCachedTemporaryLocation(
                    id: location.id, timestamp: location.timestamp,
                    stationName: location.stationName,
                    latitude: location.point.latitude, longitude: location.point.longitude,
                    reason: location.reason
                )
            }
        )
        MapHomeDayCacheMemory.store(
            payload,
            day: TaptionPlanDayKey(date: model.selectedDate),
            algorithmKey: Self.mapCacheAlgorithmKey,
            styleKey: styleKey,
            generation: generation
        )
    }

    private func reportInitialMapShellReadyIfNeeded(for date: Date) {
        // 홈은 전체 DB 로드와 오늘 경로(하루 데이터)가 준비된 뒤에 띄운다. 너무 오래 걸리면 시간 제한으로 연다.
        guard !hasReportedInitialDataReady,
              (model.isBootstrapped && dayDataSnapshot?.isComplete == true) || initialReadyForced,
              Calendar.autoupdatingCurrent.isDate(
                  date,
                  inSameDayAs: model.selectedDate
              ) else { return }
        hasReportedInitialDataReady = true
        TaptionPlanDiagnosticsLogger.shared.record("map_initial_shell_ready")
        onInitialDataReady()
    }

    private var routeOverlayCutoff: Date {
        let timelineDate = routeTimelineDate
        let calendar = Calendar.autoupdatingCurrent
        let dayStart = calendar.startOfDay(for: model.selectedDate)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)
            ?? dayStart.addingTimeInterval(24 * 60 * 60)
        return MapHomeRouteOverlayCutoffPolicy.cutoff(
            selectedDayEnd: dayEnd,
            timelineDate: timelineDate,
            isPlaybackRunning: isDayPlaybackRunning,
            interactiveProjectionCutoff: isTimelineInteractionActive
                && !isDayPlaybackRunning
                ? routeProjection?.cutoff
                : nil
        )
    }

    private func requestRouteProjectionRefresh(
        preparingReadings: Bool = false
    ) {
        guard scenePhase == .active else { return }
        guard !isTimelineInteractionActive || isDayPlaybackRunning else {
            routeDocumentProjectionGate.deferRefresh(
                preparingReadings: preparingReadings
            )
            return
        }
        if preparingReadings {
            prepareRouteProjectionReadings()
        }
        refreshRouteProjection()
        recordCurrentPlaybackAlignment()
    }

    private func scheduleLiveRouteProjectionRefresh() {
        liveRouteProjectionRefreshTask?.cancel()
        guard scenePhase == .active else {
            liveRouteProjectionRefreshTask = nil
            return
        }
        liveRouteProjectionRefreshTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 100_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled, scenePhase == .active else { return }
            mapRenderCache.invalidateRouteData()
            requestRouteProjectionRefresh(preparingReadings: true)
            if let timestamp = [
                model.latestSensorReading?.timestamp,
                model.liveRouteState.readings.last?.timestamp,
            ].compactMap({ $0 }).max() {
                removeCompletedExpectedRoutes(at: timestamp)
            }
            liveRouteProjectionRefreshTask = nil
        }
    }

    private func removeCompletedExpectedRoutes(at timestamp: Date) {
        guard !expectedRouteOverlays.isEmpty else { return }
        let travel = currentDayDataSnapshot?.travel ?? []
        let travelByID = Dictionary(
            uniqueKeysWithValues: travel.map { ($0.id, $0) }
        )
        let readings = currentDayReadings
        let completed = Set<UUID>(expectedRouteOverlays.compactMap { overlay in
            guard overlay.departureDate <= timestamp,
                  let segment = travelByID[overlay.segmentID],
                  TaptionRouteEngineAdapter.hasCompleteRecordedRoute(
                      for: segment,
                      readings: readings
                  ) else { return nil }
            return overlay.id
        })
        guard !completed.isEmpty else { return }
        expectedRouteOverlays.removeAll { completed.contains($0.id) }
        mapRenderCache.invalidateExpectedRoutes()
        refreshWBSPlaybackProjection()
        persistMapDayCache()
    }

    @discardableResult
    private func flushDeferredRouteProjection() -> RouteTimelineProjection? {
        guard let refresh = routeDocumentProjectionGate
            .consumeDeferredRefresh() else {
            return nil
        }
        if refresh.preparesReadings {
            prepareRouteProjectionReadings()
        }
        let projection = refreshRouteProjection()
        flushDeferredWBSPlaybackProjection()
        recordCurrentPlaybackAlignment()
        return projection
    }

    @discardableResult
    /// 경로 갱신을 요청하고 지금 가진 결과를 돌려준다. 계산은 백그라운드에서 하고, 끝나면 화면에 반영한다.
    private func refreshRouteProjection() -> RouteTimelineProjection? {
        scheduleRouteProjection()
        return routeProjection
    }

    /// 경로 계산을 메인 스레드 밖에서 돌린다. 입력이 같으면 이전 결과를 그대로 쓴다.
    /// 계산이 끝났을 때 입력이 이미 바뀌었다면 결과를 버린다(늦은 결과가 최신 경로를 덮지 않도록).
    private func scheduleRouteProjection() {
        guard scenePhase == .active,
              let dayData = currentDayDataSnapshot else {
            routeProjectionSkips[0] += 1
            return
        }
        let calendar = Calendar.autoupdatingCurrent
        let actuals = dayData.actuals
        let actualIndex = routeActualIndex ?? RouteTimelineDataEngine.actualIndex(
            selectedDate: model.selectedDate,
            actuals: actuals,
            calendar: calendar
        )
        if routeActualIndex == nil {
            routeActualIndex = actualIndex
        }
        let timelineDate = routeTimelineDate
        let dayStart = calendar.startOfDay(for: model.selectedDate)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)
            ?? dayStart.addingTimeInterval(24 * 60 * 60)
        let rawProjectionDate = MapHomeRouteOverlayCutoffPolicy.cutoff(
            selectedDayEnd: dayEnd,
            timelineDate: timelineDate,
            isPlaybackRunning: isDayPlaybackRunning
        )
        // 재생 중에는 분 단위로 잘라, 같은 분 안의 틱이 투영을 다시 만들지 않게 한다(PLY1029A01).
        let projectionDate = isDayPlaybackRunning
            ? Date(timeIntervalSinceReferenceDate: (rawProjectionDate.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60)
            : rawProjectionDate
        let selectedSpan = isDayPlaybackRunning ? nil : timelineSelectionSpan
        let readings = displayRouteReadings
        let inputKey = RouteProjectionInputKey(
            day: dayStart,
            sourceRevision: dayData.sourceRevision,
            cutoff: projectionDate,
            selectedStart: selectedSpan?.start,
            selectedEnd: selectedSpan?.end,
            isPlaying: isDayPlaybackRunning,
            readingCount: readings.count,
            lastReadingTime: readings.last?.timestamp,
            actualCount: actuals.count,
            sleepCount: model.sleepSessions.count,
            confirmedSleepCount: model.settings.confirmedSleepSpans.count
        )
        if inputKey == routeProjectionInputKey, routeProjection != nil {
            routeProjectionSkips[1] += 1
            return
        }
        // 재생 중에는 계산이 끝나기 전에 입력이 바뀌어도 작업을 끊지 않는다. 매초 끊으면 결과가 한 번도 반영되지 않아
        // 발자국과 경로가 재생이 끝날 때까지 나오지 않았다. 끝나면 가장 최근 입력으로 한 번 더 계산한다(ARC1030A02).
        if isDayPlaybackRunning, routeProjectionInFlight {
            routeProjectionDirty = true
            routeProjectionSkips[2] += 1
            return
        }
        routeProjectionInputKey = inputKey
        let travel = dayData.travel
        let confirmedSleepSpans = model.settings.confirmedSleepSpans
        let sleepSessions = model.sleepSessions
        let selectedDate = model.selectedDate
        routeProjectionTask?.cancel()
        routeProjectionRunID &+= 1
        let runID = routeProjectionRunID
        routeProjectionInFlight = true
        let runStart = ProcessInfo.processInfo.systemUptime
        routeProjectionTask = Task { @MainActor in
            let next = await Task.detached(priority: .userInitiated) {
                RouteTimelineDataEngine.project(
                    selectedDate: selectedDate,
                    through: projectionDate,
                    selectedSpan: selectedSpan,
                    actuals: actuals,
                    actualIndex: actualIndex,
                    travel: travel,
                    readings: readings,
                    readingsAreNormalized: true,
                    filtersSparseRouteConnections: true,
                    confirmedSleepSpans: confirmedSleepSpans,
                    sleepSessions: sleepSessions,
                    calendar: calendar
                )
            }.value
            if routeProjectionRunID == runID { routeProjectionInFlight = false }
            routeProjectionLastMS = (ProcessInfo.processInfo.systemUptime - runStart) * 1000
            guard !Task.isCancelled else { return }
            // 재생 중에는 조금 늦은 결과도 쓴다(같은 재생이면 입력이 이미 다음 분으로 넘어가 있어도 괜찮다).
            guard routeProjectionInputKey == inputKey || (isDayPlaybackRunning && inputKey.isPlaying) else { return }
            let overlays = makeTimelineRouteOverlays(next)
            mapRenderCache.invalidateRouteData()
            routeProjection = next
            timelineRouteOverlays = overlays
            routeProjectionApplied += 1
            if routeProjectionDirty, isDayPlaybackRunning {
                routeProjectionDirty = false
                scheduleRouteProjection()
            }
        }
    }

    private func prepareRouteProjectionReadings() {
        guard scenePhase == .active else { return }
        let calendar = Calendar.autoupdatingCurrent
        let dayStart = calendar.startOfDay(for: model.selectedDate)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)
            ?? dayStart.addingTimeInterval(24 * 60 * 60)
        let preparationSignature = [
            String(dayStart.timeIntervalSinceReferenceDate),
            String(model.dayProjectionRevision),
            String(transitBoardingReadingsRevision),
            String(routeReadings.count),
            routeReadings.last?.id.uuidString ?? "none",
            String(model.liveRouteState.readings.count),
            model.liveRouteState.readings.last?.id.uuidString ?? "none",
            model.liveRouteState.lastUpdatedAt.map {
                String($0.timeIntervalSinceReferenceDate)
            } ?? "none",
            model.latestSensorReading?.id.uuidString ?? "none",
            model.latestSensorReading.map {
                String($0.timestamp.timeIntervalSinceReferenceDate)
            } ?? "none",
            MapHomeRouteReadingsPreparation.latestRouteInputSignature(
                model.latestSensorReading
            ),
        ].joined(separator: "|")
        guard preparationSignature != lastPreparedRouteReadingsSignature else {
            if routeReadingsPreparationTask == nil {
                requestWBSPlaybackProjectionRefresh()
            }
            return
        }
        lastPreparedRouteReadingsSignature = preparationSignature
        routeReadingsPreparationTask?.cancel()
        let preparationID = routeReadingsPreparationGeneration.advance()
        let routeReadingsSnapshot = routeReadings
        let liveReadingsSnapshot = model.liveRouteState.readings
        let latestReading = model.latestSensorReading
        routeReadingsPreparationTask = Task { @MainActor in
            let worker = Task.detached(priority: .utility) {
                try MapHomeRouteReadingsPreparation.prepare(
                    routeReadings: routeReadingsSnapshot,
                    liveReadings: liveReadingsSnapshot,
                    latestReading: latestReading,
                    dayStart: dayStart,
                    dayEnd: dayEnd,
                    cancellationCheck: { try Task.checkCancellation() }
                )
            }
            let prepared: MapHomePreparedRouteReadings
            do {
                prepared = try await withTaskCancellationHandler(
                    operation: { try await worker.value },
                    onCancel: { worker.cancel() }
                )
            } catch {
                worker.cancel()
                guard routeReadingsPreparationGeneration.accepts(preparationID) else {
                    return
                }
                routeReadingsPreparationTask = nil
                lastPreparedRouteReadingsSignature = nil
                return
            }
            guard !Task.isCancelled,
                  routeReadingsPreparationGeneration.accepts(preparationID),
                  lastPreparedRouteReadingsSignature == preparationSignature,
                  scenePhase == .active else { return }
            normalizedRouteReadings = prepared.normalized
            if currentMapLocationReading != prepared.latestTrustedReading {
                currentMapLocationReading = prepared.latestTrustedReading
            }
            historicalPlaybackReadings = prepared.normalized
            displayRouteReadings = prepared.display
            routeReadingsPreparationTask = nil
            TaptionPlanDiagnosticsLogger.shared.record(
                "map_route_readings_prepared",
                fields: [
                    "day_start": String(dayStart.timeIntervalSince1970),
                    "source_readings": String(prepared.sourceCount),
                    "impossible_location_count": String(prepared.impossibleLocationCount),
                    "innovation_outlier_count": String(prepared.innovationOutlierCount),
                    "filtered_readings": String(prepared.filteredCount),
                    "normalized_readings": String(prepared.normalized.count),
                    "display_readings": String(prepared.display.count),
                    "watch_source_readings": String(prepared.watchSourceCount),
                    "readings_with_point": String(prepared.readingsWithPointCount),
                    "readings_rail_match": String(prepared.railMatchCount),
                    "readings_station_name": String(prepared.stationNameCount),
                ].merging(
                    MapHomeRouteJumpDiagnostics.fields(for: prepared.display),
                    uniquingKeysWith: { first, _ in first }
                )
            )
            requestRouteProjectionRefresh()
            requestWBSPlaybackProjectionRefresh()
            scheduleExpectedRouteRefresh()
        }
    }

    private func requestWBSPlaybackProjectionRefresh() {
        guard scenePhase == .active else {
            hasDeferredWBSPlaybackRefresh = true
            return
        }
        guard !isTimelineInteractionActive || isDayPlaybackRunning else {
            hasDeferredWBSPlaybackRefresh = true
            return
        }
        refreshWBSPlaybackProjection()
    }

    private func flushDeferredWBSPlaybackProjection() {
        if let pendingForecastRouteState {
            self.pendingForecastRouteState = nil
            hasDeferredWBSPlaybackRefresh = false
            if !applyForecastRouteState(pendingForecastRouteState) {
                refreshWBSPlaybackProjection()
            }
            return
        }
        guard hasDeferredWBSPlaybackRefresh else { return }
        hasDeferredWBSPlaybackRefresh = false
        refreshWBSPlaybackProjection()
    }

    private func refreshWBSPlaybackProjection() {
        guard scenePhase == .active else {
            hasDeferredWBSPlaybackRefresh = true
            return
        }
        hasDeferredWBSPlaybackRefresh = false
        var next = makeWBSPlaybackProjection(
            expected: expectedRouteOverlays,
            generated: wbsGeneratedRouteOverlays
        )
        let activeGeneratedIDs = Set(next.legs.compactMap { leg in
            leg.routePhase == .forecast && leg.activity == .movement
                ? leg.id
                : nil
        })
        let generated = wbsGeneratedRouteOverlays.filter {
            activeGeneratedIDs.contains($0.id)
        }
        if generated.count != wbsGeneratedRouteOverlays.count {
            wbsGeneratedRouteOverlays = generated
            mapRenderCache.invalidateExpectedRoutes()
            next = makeWBSPlaybackProjection(
                expected: expectedRouteOverlays,
                generated: generated
            )
        }
        if wbsPlaybackProjection != next {
            wbsPlaybackProjection = next
        }
        syncPlaybackDriverProjection()
    }

    /// 예상 경로 요청을 만드는 쪽과 같은 하루 범위를 쓴다. 범위가 어긋나면 같은
    /// 이동 구간이라도 요청 id가 달라져 재생 leg와 화면의 경로가 연결되지 않는다.
    private static func routeDaySpan(for date: Date) -> TimeSpan {
        let calendar = Calendar.autoupdatingCurrent
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start)
            ?? start.addingTimeInterval(24 * 60 * 60)
        return TimeSpan(start: start, end: end)
    }

    private func makeWBSPlaybackProjection(
        expected: [MapHomeExpectedRouteOverlay],
        generated: [MapHomeWBSGeneratedRouteOverlay],
        expectedRouteRequests: [ExpectedRouteRequest]? = nil
    ) -> MapHomeWBSPlaybackProjection {
        let dayData = currentDayDataSnapshot
        let playbackRequests: [ExpectedRouteRequest]?
        if let expectedRouteRequests {
            playbackRequests = expectedRouteRequests
        } else if wbsExpectedRouteRequestsInputKey == currentExpectedRouteInputKey() {
            playbackRequests = wbsExpectedRouteRequests
        } else {
            // 입력이 바뀐 뒤 아직 예상 경로 요청을 다시 만들지 않은 상태다. 여기서
            // 빈 배열을 넘기면 예상 이동 구간이 하나도 없는 투영이 만들어지고,
            // 확정된 장소가 없는 미확정 경로에서는 화랑이가 설 자리가 없어 사라진다.
            // 예상 경로 갱신과 같은 입력으로 다시 계산해 leg id를 맞춘다.
            let daySpan = Self.routeDaySpan(for: model.selectedDate)
            playbackRequests = ExpectedRouteRequestEngine.requests(
                travel: dayData?.travel ?? [],
                places: [],
                readings: normalizedRouteReadings,
                in: daySpan,
                through: daySpan.end,
                frequentPlaces: [],
                gpsLoggingInterval: model.settings.gpsLoggingPreferences.interval
            )
        }
        let expectedRoutes = expected.map { overlay in
            MapHomeWBSResolvedRoute(
                legID: "movement-\(overlay.id.uuidString)",
                coordinates: overlay.coordinates.map(wbsGeoPoint)
            )
        }
        let generatedRoutes = generated.map { overlay in
            MapHomeWBSResolvedRoute(
                legID: overlay.id,
                coordinates: overlay.coordinates.map(wbsGeoPoint)
            )
        }
        return MapHomeWBSPlaybackProjection.make(
            selectedDate: model.selectedDate,
            places: dayData?.places ?? [],
            travel: dayData?.travel ?? [],
            readings: currentDayReadings,
            expectedRouteRequests: playbackRequests,
            resolvedRoutes: expectedRoutes + generatedRoutes + storedWBSResolvedRoutes,
            actuals: dayData?.actuals ?? [],
            confirmedSleepSpans: model.settings.confirmedSleepSpans,
            sleepSessions: model.sleepSessions
        )
    }

    private var storedWBSResolvedRoutes: [MapHomeWBSResolvedRoute] {
        (currentDayDataSnapshot?.travel ?? []).compactMap { segment in
            guard segment.mode == .subway,
                  segment.isConfirmed,
                  let route = segment.subwayRoute,
                  SubwayStationCatalog.isValid(route),
                  route.coordinates.count >= 2 else { return nil }
            return MapHomeWBSResolvedRoute(
                legID: "movement-\(segment.id.uuidString)",
                coordinates: route.coordinates
            )
        }
    }

    private func wbsGeoPoint(
        _ coordinate: CLLocationCoordinate2D
    ) -> GeoPoint {
        GeoPoint(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            altitude: 0,
            horizontalAccuracy: -1,
            verticalAccuracy: -1
        )
    }

    private func recordCurrentPlaybackAlignment() {
        if let frame = wbsPlaybackFrame, selectedPawprintPoint == nil {
            recordPlaybackRouteAlignment(frame)
        }
    }

    private func recordPlaybackRouteAlignment(
        _ frame: MapHomeWBSPlaybackFrame
    ) {
        let dottedLegIDs = visibleForecastPlaybackLegIDs
        let cutoffDelta = routeOverlayCutoff.timeIntervalSince(
            displayedLocationDate
        )
        TaptionPlanDiagnosticsLogger.shared.record(
            "expected_route_playback_alignment",
            fields: [
                "frame_leg_id": frame.legID,
                "frame_phase": frame.routePhase.rawValue,
                "frame_activity": frame.activity == .movement
                    ? "movement"
                    : "stay",
                "frame_progress": String(frame.progress),
                "forecast_overlay_count": String(dottedLegIDs.count),
                "frame_matches_forecast_overlay": String(
                    dottedLegIDs.contains(frame.legID)
                ),
                "cutoff_delta_seconds": String(cutoffDelta),
                "is_playback_running": String(isDayPlaybackRunning),
            ]
        )
    }

    private func clampedTimelineDate(
        _ date: Date,
        now: Date = .now,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Date {
        MapHomeRouteReadingsPolicy.clampedTimelineDate(
            selectedDate: model.selectedDate,
            timelineDate: date,
            now: now,
            calendar: calendar
        )
    }

    private var dateTitle: String {
        MapHomeDateText.string(
            from: model.selectedDate,
            format: selectedScope == .day
                ? language.dateTitleFormat
                : language.monthTitleFormat,
            locale: language.locale
        )
    }

    private var dateTitleLabel: Text {
        let weekday = Calendar.autoupdatingCurrent.component(.weekday, from: model.selectedDate)
        let weekdayName = MapHomeDateText.string(
            from: model.selectedDate, format: language.weekdayFormat, locale: language.locale)
        let weekdayText = Text(" \(weekdayName)")
            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(17)), weight: .semibold))
            .foregroundStyle(dateColor(weekday: weekday))
        return datePartTitleLabel + weekdayText
    }

    private var datePartTitleLabel: Text {
        let datePart = MapHomeDateText.string(
            from: model.selectedDate, format: language.datePartFormat, locale: language.locale)
        return Text(datePart)
            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(17)), weight: .semibold))
            .foregroundStyle(
                dateColor(
                    weekday: Calendar.autoupdatingCurrent.component(
                        .weekday,
                        from: model.selectedDate
                    )
                )
            )
    }

    private var ink: Color {
        .tpInk
    }

    private func dateColor(weekday: Int) -> Color {
        if weekday == 7 { return .tpSaturday }
        if TimelineAxisGrid.koreanHolidayName(on: model.selectedDate) != nil || weekday == 1 {
            return .tpHoliday
        }
        return ink
    }

    private func jumpToTodayAndCurrentMapPosition() {
        shouldFitRoutesAfterDateChange = true
        hasUserAdjustedMap = false
        model.selectedDate = Date()
        selectedTimelineMinute = nil
        isTimelineSelectionPinned = false
        sharedZoomLevel = 1
        zoomResetToken += 1
        focusMapOnAllRoutes()
    }

    private func setMapPosition(_ position: MapCameraPosition, caller: String = #function) {
        mapPosition = position
        mapCameraRevision &+= 1
        // 재생 중에는 초당 한 번만 기록해 로그 양을 줄인다.
        if isDayPlaybackRunning,
           !MapHomeCameraLogThrottle.shouldLog(nowUptime: ProcessInfo.processInfo.systemUptime) { return }
        TaptionPlanDiagnosticsLogger.shared.record(
            "map_camera_command",
            fields: [
                "caller": caller,
                "tracking": String(describing: userTrackingMode),
                "playing": isDayPlaybackRunning ? "true" : "false",
            ],
            metrics: [
                "revision": Double(mapCameraRevision),
                "distance_m": position.camera?.distance.rounded() ?? -1,
            ]
        )
    }

    private func restoreInitialMapZoom() {
        let camera = MapHomeStartupCameraPolicy.camera(
            restoring: visibleMapCamera,
            fallbackCenter: displayedLocationCoordinate ?? currentCoordinate
                ?? MapHomeStartupCameraPolicy.fallbackCenter
        )
        mapCameraFrameProjection.reset()
        if visibleMapCamera != camera { visibleMapCamera = camera }
        setMapPosition(.camera(camera))
    }

    /// 날씨 표시 값. `onChange(of: model.snapshot.weather)`가 이미 합쳐 두므로 본문에서 다시 합치지 않는다.
    /// 예전에는 화면이 그려질 때마다 최대 512개를 다시 합쳐 재생 중 메인 스레드의 15%를 썼다(ARC1030A01).
    private var displayWeatherContexts: [WeatherContext] {
        cachedWeatherContexts.isEmpty ? model.snapshot.weather : cachedWeatherContexts
    }

    /// 일정·스티커 배지의 기준 x. 날씨 배지가 켜져 있으면 날씨 왼쪽(왼쪽 정렬), 꺼져 있으면 시간 레일 오른쪽(오른쪽 정렬).
    private var scheduleBadgeBaseX: CGFloat {
        // 날씨 칩이 실제로 보일 때만 왼쪽에 붙이고, 날씨 칩이 없으면 오른쪽에 붙인다.
        let hasWeatherChips = recordingShows(\.weatherSidebar)
            && !displayWeatherContexts.isEmpty
        return hasWeatherChips
            ? MapHomeTimeSidebarMath.handleLaneWidth - 41
            : MapHomeTimeSidebarMath.handleLaneWidth + 8
    }

    /// 같은 시간(±10분)에 일정과 스티커가 함께 있으면 일정은 왼쪽, 스티커는 오른쪽으로 나눈다. 아니면 기본 위치.
    private func scheduleBadgeOffset(minute: Int, isEvent: Bool) -> CGFloat {
        let timedEvents = dayCalendarEventsForSelectedDate.filter { !$0.isAllDay }.map { minuteOfDay(for: $0.span.start) }
        let timedStickers = scheduleStickersForSelectedDate.map { minuteOfDay(for: $0.occurredAt) }
            + timedMemosForSelectedDate.map { minuteOfDay(for: $0.occurredAt) }
        let others = isEvent ? timedStickers : timedEvents
        guard others.contains(where: { abs($0 - minute) <= 10 }) else { return 0 }
        return isEvent ? -14 : 14
    }

    private func minuteOfDay(for date: Date) -> Int {
        let components = Calendar.autoupdatingCurrent.dateComponents([.hour, .minute, .second], from: date)
        return min(1_439, max(0, (components.hour ?? 0) * 60 + (components.minute ?? 0)))
    }

    private func moveDate(by amount: Int) {
        let component: Calendar.Component = switch selectedScope {
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        case .year: .year
        }
        if let date = Calendar.autoupdatingCurrent.date(byAdding: component, value: amount, to: model.selectedDate) {
            model.selectedDate = date
        }
    }

    private func focusMapIfNeeded() {
        applyInitialMapFocusIfNeeded()
    }

    private func applyInitialMapFocusIfNeeded() {
        guard !isDayPlaybackRunning, !hasUserAdjustedMap,
              !hasAppliedInitialMapFocus,
              let coordinate = displayedLocationCoordinate ?? currentCoordinate else { return }
        hasAppliedInitialMapFocus = true
        hasAppliedInitialLocation = true
        setMapPosition(.camera(MapCamera(centerCoordinate: coordinate, distance: MapHomeStartupCameraPolicy.distance)))
    }

    private var mapRouteFitRegion: MKCoordinateRegion? {
        var coordinates = timelineRouteOverlays.flatMap(\.coordinates)
            + displayedExpectedRouteOverlays.flatMap(\.coordinates)
            + displayedWBSGeneratedRouteOverlays.flatMap(\.coordinates)
            + subwayRouteOverlays.flatMap(\.coordinates)
        if coordinates.isEmpty, let currentCoordinate {
            coordinates = [currentCoordinate]
        }
        return MapHomeRouteFitMath.region(for: coordinates)
    }

    private func sharedZoomLevel(for span: MKCoordinateSpan) -> CGFloat? {
        guard let bounds = mapRenderCache.bounds(
            timeline: timelineRouteOverlays,
            expected: displayedExpectedRouteOverlays,
            generated: displayedWBSGeneratedRouteOverlays,
            subway: subwayRouteOverlays,
            current: currentCoordinate
        ) else { return nil }
        let fitLatitude = max(
            0.025,
            (bounds.maxLatitude - bounds.minLatitude) * 1.8
        )
        let fitLongitude = max(
            0.035,
            (bounds.maxLongitude - bounds.minLongitude) * 1.8
        )
        let scale = max(span.latitudeDelta / fitLatitude, span.longitudeDelta / fitLongitude)
        return min(max((scale - 0.05) / 0.95, 0), 1)
    }

    /// 배율 숫자를 누르면 이동 경로 전체가 보이도록 배율과 위치를 맞춘다. 따라가기는 멈춘다.
    private func fitMapToRoutes() {
        guard !isDayPlaybackRunning, let region = mapRouteFitRegion else { return }
        setUserTrackingMode(.idle)
        isMapCenteredOnUser = false
        hasUserAdjustedMap = true
        setMapPosition(.region(region))
    }

    /// 집 위치로 카메라를 옮긴다. 땅 한 칸이 보이는 거리(집 주변 땅 타일의 최소 표시 크기 이상)로 확대한다.
    private func focusMapOnHome() {
        guard let home = model.settings.frequentPlaces.first(where: { $0.kind == .home })?.point else {
            isHomeMissingAlertPresented = true
            return
        }
        hasUserAdjustedMap = true
        // 집 버튼도 배율 80으로 맞춘다. 자동 줌이 곧바로 덮어쓰지 않도록 잠시 멈춘다.
        liveZoomGovernor.pauseForUserAdjustment(uptime: ProcessInfo.processInfo.systemUptime)
        setMapPosition(.camera(
            MapCamera(
                centerCoordinate: CLLocationCoordinate2D(latitude: home.latitude, longitude: home.longitude),
                distance: MapHomeCameraZoomMath.distance(forScale: 80),
                heading: 0,
                pitch: 0
            )
        ))
    }

    /// 하루요약 시트가 지도를 덮은 만큼 집을 남은 영역의 가운데로 옮긴다.
    /// 시트를 내리면 다시 지도 전체 가운데로 돌아온다. 배율·방향은 그대로 둔다.
    /// 하루 요약 시트가 올라올 때 화면 위쪽에 남길 기준점. 화랑이에서 열었고 집 밖이면 화랑이, 아니면 집.
    private var daySummaryCameraAnchor: CLLocationCoordinate2D? {
        if daySummaryFocusesCat, !isDisplayedCatAtHome, let cat = displayedLocationCoordinate {
            return cat
        }
        guard let home = model.settings.frequentPlaces.first(where: { $0.kind == .home })?.point else { return nil }
        return CLLocationCoordinate2D(latitude: home.latitude, longitude: home.longitude)
    }

    private func applyDaySummaryCameraCoverage() {
        let coverage = daySummaryCoverage
        guard abs(coverage - daySummaryAppliedCoverage) > 0.001 else { return }
        // 재생 중이거나 위치를 따라가는 중에는 카메라가 다른 곳에서 움직인다. 손대지 않는다.
        guard !isDayPlaybackRunning, userTrackingMode == .idle else { return }
        guard mapViewportSize.height > 0,
              let camera = visibleMapCamera,
              let anchor = daySummaryCameraAnchor
        else { return }
        let shift = MapHomeDaySummaryLayout.centerShift(
            viewportHeight: mapViewportSize.height,
            coverage: coverage
        )
        let latitudeShift = MapHomeDaySummaryLayout.latitudeShift(
            shift: shift,
            viewportHeight: mapViewportSize.height,
            latitudeDelta: visibleMapSpan.latitudeDelta
        )
        // 중심을 아래(남쪽)로 내리면 기준점(집 또는 화랑이)은 그만큼 화면 위로 올라온다.
        let center = CLLocationCoordinate2D(
            latitude: anchor.latitude - latitudeShift,
            longitude: anchor.longitude
        )
        daySummaryAppliedCoverage = coverage
        setMapPosition(.camera(MapCamera(
            centerCoordinate: center,
            distance: camera.distance,
            heading: camera.heading,
            pitch: camera.pitch
        )))
        // Apple 지도는 아직 반영되지 않은 뷰포트 명령이 있으면 카메라 명령을 건너뛴다.
        // 같은 중심으로 뷰포트 명령도 보내 어느 쪽이 적용돼도 집이 같은 자리에 오게 한다.
        if !rendersVectorMap {
            appleViewportCommand = MapHomeAppleViewportCommand(
                revision: (appleViewportCommand?.revision ?? 0) &+ 1,
                centerCoordinate: center,
                heading: nil,
                targetPoint: nil
            )
        }
    }

    private func focusMapOnAllRoutes() {
        guard MapHomePlaybackCameraPolicy.allowsAutomaticFit(
            isPlaybackRunning: isDayPlaybackRunning,
            hasUserAdjustedMap: hasUserAdjustedMap
        ) else { return }
        guard let region = mapRouteFitRegion else {
            setMapPosition(.automatic)
            return
        }
        setMapPosition(.region(region))
    }

    /// 실시간 따라가기 중 최신 센서 속도. 오래된 값은 쓰지 않는다.
    private var liveFollowSpeedMetersPerSecond: Double? {
        guard let reading = model.latestSensorReading else { return nil }
        return MapHomeLiveFollowSpeed.speed(
            latestAge: Date.now.timeIntervalSince(reading.timestamp),
            latestSpeed: reading.speedMetersPerSecond
        )
    }

    /// 재생 중 화랑이가 화면 가운데에서 얼마나 벗어났는지 1초에 한 번 기록한다(좌표 없이 픽셀과 유무만).
    private func recordPlaybackFocusSample() {
        guard TimelineInteractionFrameGate.shouldRender(
            lastUptime: &lastPlaybackFocusLogUptime,
            nowUptime: ProcessInfo.processInfo.systemUptime,
            minimumInterval: 1
        ) else { return }
        let center = currentLocationTargetPoint
        let offset = displayedStickmanViewportPoint.map {
            hypot($0.x - center.x, $0.y - center.y)
        }
        TaptionPlanDiagnosticsLogger.shared.record(
            "playback_focus_sample",
            metrics: [
                "has_point": displayedPlaybackFocusPoint == nil ? 0 : 1,
                "has_camera": visibleMapCamera == nil ? 0 : 1,
                "stickman_offset_px": offset?.rounded() ?? -1,
                "camera_distance_m": visibleMapCamera?.distance.rounded() ?? -1,
                "speed_mps": displayedSpeedMetersPerSecond ?? -1,
            ]
        )
    }

    /// Apple 지도의 재생 중 속도 비례 줌. 가운데 맞추기는 지도 뷰가 하고, 여기서는 거리만 바꾼다.
    private func advanceApplePlaybackZoom() {
        guard isDayPlaybackRunning,
              !isPlaybackIntroActive,
              TimelineInteractionFrameGate.shouldRender(
                  lastUptime: &lastPlaybackMapFocusUptime,
                  nowUptime: ProcessInfo.processInfo.systemUptime,
                  minimumInterval: MapHomeDayPlaybackMath.mapFocusInterval
              ),
              let camera = visibleMapCamera,
              let point = displayedPlaybackFocusPoint else { return }
        let next = playbackAwareDistance(current: camera.distance)
        guard abs(next - camera.distance) / camera.distance >= 0.01 else { return }
        requestAppleMapCenter(
            CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude),
            distance: next
        )
    }

    /// 멈춰 있어 새 위치가 오지 않아도 기본 거리까지 확대를 이어 간다(2초 간격 한 걸음씩).
    private func advanceStationaryZoomIfNeeded() {
        guard scenePhase == .active,
              MapHomeUserTrackingPolicy.focusesLocationUpdates(in: userTrackingMode),
              liveFollowSpeedMetersPerSecond == 0,
              let camera = visibleMapCamera,
              abs(log(camera.distance / MapHomePlaybackZoomPolicy.baselineDistance)) >= MapHomeLiveZoomGovernor.hysteresis
        else { return }
        focusDisplayedLocation(using: nil)
    }

    /// 오늘의 실시간 따라가기에서 속도에 맞춘 거리. 바꾸지 않아야 하면 nil.
    private func liveFollowDistance(current: Double) -> Double? {
        // 설정의 "속도에 따라 가변"이 꺼져 있으면 실시간 따라가기에서도 배율을 바꾸지 않는다.
        // 예전에는 이 설정이 재생에만 적용돼 실시간 따라가기는 켜고 꺼도 늘 속도에 따라 줌이 바뀌었다(대표 지적, ARC1030A04).
        guard MapHomePlaybackZoomMode(rawValue: playbackZoomModeRaw) != .fixed,
              !isDayPlaybackRunning,
              selectedTimelineMinute == nil,
              userTrackingMode == .following,
              Calendar.autoupdatingCurrent.isDateInToday(model.selectedDate),
              let next = liveZoomGovernor.nextDistance(
                  current: current,
                  speedMetersPerSecond: liveFollowSpeedMetersPerSecond,
                  uptime: ProcessInfo.processInfo.systemUptime
              ), abs(next - current) >= 1 else { return nil }
        TaptionPlanDiagnosticsLogger.shared.record(
            "live_zoom_sample",
            metrics: [
                "speed_mps": liveFollowSpeedMetersPerSecond ?? -1,
                "current_m": current.rounded(),
                "next_m": next.rounded(),
            ]
        )
        return next
    }

    /// 재생 중에는 속도에 맞춘 거리를, 실시간 따라가기에서는 속도 비례 줌을, 아니면 현재 거리를 돌려준다.
    private func playbackAwareDistance(current: Double) -> Double {
        guard isDayPlaybackRunning else {
            return liveFollowDistance(current: current) ?? current
        }
        guard MapHomePlaybackZoomMode(rawValue: playbackZoomModeRaw) != .fixed else {
            return current
        }
        let playbackMinute = dayPlaybackCurrentMinute ?? Double(selectedTimelineMinute ?? 0)
        let target = playbackZoomPlan.targetDistance(
            atMinute: playbackMinute,
            speedMetersPerSecond: displayedSpeedMetersPerSecond
        )
        let next = playbackZoomSmoother.next(
            current: current,
            target: target,
            uptime: ProcessInfo.processInfo.systemUptime
        )
        TaptionPlanDiagnosticsLogger.shared.record(
            "playback_zoom_sample",
            metrics: [
                "plan_scale": playbackZoomPlan.scale(atMinute: playbackMinute),
                "current_m": current.rounded(),
                "target_m": target.rounded(),
                "next_m": next.rounded(),
            ]
        )
        return next
    }

    private func focusMap(
        on point: GeoPoint,
        using proxy: MapProxy? = nil,
        followsTracking: Bool = false
    ) {
        let coordinate = CLLocationCoordinate2D(
            latitude: point.latitude,
            longitude: point.longitude
        )
        if followsTracking,
           let proxy,
           let camera = visibleMapCamera,
           let locationPoint = proxy.convert(
               coordinate,
               to: .named("mapHomeViewport")
           ),
           let center = proxy.convert(
               MapHomeCameraLayoutMath.cameraCenterSourcePoint(
                   currentLocationPoint: locationPoint,
                   targetPoint: currentLocationTargetPoint,
                   viewportSize: mapViewportSize
               ),
               from: .named("mapHomeViewport")
           ) {
            setMapPosition(.camera(
                MapCamera(
                    centerCoordinate: center,
                    distance: playbackAwareDistance(current: camera.distance),
                    heading: camera.heading,
                    pitch: camera.pitch
                )
            ))
        } else if let camera = visibleMapCamera {
            setMapPosition(.camera(
                MapCamera(
                    centerCoordinate: coordinate,
                    distance: playbackAwareDistance(current: camera.distance),
                    heading: camera.heading,
                    pitch: camera.pitch
                )
            ))
        } else {
            setMapPosition(.region(
                MKCoordinateRegion(center: coordinate, span: visibleMapSpan)
            ))
        }
        if followsTracking {
            requestAppleMapCenter(coordinate)
        }
        if followsTracking {
            setUserTrackingMode(.following)
            isMapCenteredOnUser = true
        } else {
            setUserTrackingMode(.idle)
            isMapCenteredOnUser = false
        }
    }

    private func focusDisplayedLocation(using proxy: MapProxy?) {
        // 재생 구동기가 카메라를 맡는 동안은 센서·경로 갱신이 와도 카메라를 다시 놓지 않는다. 그 호출은 카메라 번호를 올려
        // 화면 전체를 다시 그리고 구동기가 놓은 카메라를 되돌렸다(PLY1029A10).
        guard playbackDriver == nil else { return }
        if selectedTimelineMinute != nil {
            guard let point = displayedPlaybackFocusPoint else { return }
            focusMap(on: point, using: proxy, followsTracking: true)
        } else {
            focusUserLocation(using: proxy, preservesCamera: true)
        }
    }

    private func focusUserLocation(
        using proxy: MapProxy? = nil,
        heading: CLLocationDirection? = nil,
        preservesCamera: Bool = false
    ) {
        guard let coordinate = liveFocusCoordinate else {
            isMapCenteredOnUser = false
            return
        }

        if preservesCamera, !rendersVectorMap {
            let distance = visibleMapCamera.flatMap {
                liveFollowDistance(current: $0.distance)
            }
            if let heading {
                requestAppleMapHeading(heading, centeredAt: coordinate, distance: distance)
            } else {
                requestAppleMapCenter(coordinate, distance: distance)
            }
            return
        }

        if let proxy,
           let camera = visibleMapCamera,
           let locationPoint = proxy.convert(
               coordinate,
               to: .named("mapHomeViewport")
           ),
           let center = proxy.convert(
                MapHomeCameraLayoutMath.cameraCenterSourcePoint(
                    currentLocationPoint: locationPoint,
                    targetPoint: currentLocationTargetPoint,
                    viewportSize: mapViewportSize
                ),
                from: .named("mapHomeViewport")
           ) {
            setMapPosition(.camera(
                MapCamera(
                    centerCoordinate: center,
                    distance: playbackAwareDistance(current: camera.distance),
                    heading: heading ?? camera.heading,
                    pitch: camera.pitch
                )
            ))
        } else if let camera = visibleMapCamera {
            setMapPosition(.camera(
                MapCamera(
                    centerCoordinate: coordinate,
                    distance: playbackAwareDistance(current: camera.distance),
                    heading: heading ?? camera.heading,
                    pitch: camera.pitch
                )
            ))
        } else {
            let span = preservesCamera
                ? visibleMapSpan
                : MKCoordinateSpan(latitudeDelta: 0.008, longitudeDelta: 0.010)
            setMapPosition(.region(
                MKCoordinateRegion(
                    center: coordinate,
                    span: span
                )
            ))
        }
        if !rendersVectorMap {
            if let heading {
                requestAppleMapHeading(heading, centeredAt: coordinate)
            } else {
                requestAppleMapCenter(coordinate)
            }
        }
    }

    private func requestAppleMapCenter(
        _ coordinate: CLLocationCoordinate2D,
        distance: CLLocationDistance? = nil
    ) {
        appleViewportCommand = MapHomeAppleViewportCommand(
            revision: (appleViewportCommand?.revision ?? 0) &+ 1,
            centerCoordinate: coordinate,
            heading: nil,
            targetPoint: currentLocationTargetPoint,
            distance: distance
        )
    }

    private func requestAppleMapHeading(
        _ heading: CLLocationDirection,
        centeredAt coordinate: CLLocationCoordinate2D?,
        distance: CLLocationDistance? = nil
    ) {
        appleViewportCommand = MapHomeAppleViewportCommand(
            revision: (appleViewportCommand?.revision ?? 0) &+ 1,
            centerCoordinate: coordinate,
            heading: heading,
            targetPoint: coordinate == nil ? nil : currentLocationTargetPoint,
            distance: distance
        )
    }

    /// 현재 위치 버튼: 배율은 80으로 고정한다(현재 배율에서 80으로 옮긴다). 방향과 기울기는 그대로 둔다.
    private func focusCurrentLocationAtFixedScale() {
        let camera = visibleMapCamera
        let coordinate = currentCoordinate ?? visibleMapCenter
        let distance = MapHomeCameraZoomMath.distance(forScale: 80)
        // 하루요약 시트가 아래를 덮으면 가려지지 않은 영역의 가운데에 오도록 중심을 남쪽으로 내린다.
        var center = coordinate
        if let camera, camera.distance > 0, mapViewportSize.height > 0 {
            let shift = MapHomeDaySummaryLayout.centerShift(
                viewportHeight: mapViewportSize.height,
                coverage: daySummaryCoverage
            )
            center.latitude -= MapHomeDaySummaryLayout.latitudeShift(
                shift: shift,
                viewportHeight: mapViewportSize.height,
                latitudeDelta: visibleMapSpan.latitudeDelta * distance / camera.distance
            )
        }
        setMapPosition(.camera(MapCamera(
            centerCoordinate: center,
            distance: distance,
            heading: camera?.heading ?? 0,
            pitch: camera?.pitch ?? 0
        )))
        if !rendersVectorMap {
            requestAppleMapCenter(coordinate, distance: distance)
        }
    }

    /// 위젯·알림·URL이 남긴 이동 요청을 한 번만 적용한다. 소비 즉시 지우지
    /// 않으면 화면이 다시 나타날 때마다 같은 곳으로 끌려간다. 상점 잠금 때문에
    /// 지도 홈이 아직 없을 때 들어온 요청도 잠금이 풀린 뒤 `onAppear`에서 온다.
    private func applyPendingMapHomeRoute() {
        guard let route = model.pendingMapHomeRoute else { return }
        model.pendingMapHomeRoute = nil
        route.apply(
            openDaySummary: { isDaySummaryPresented = true },
            followLiveLocation: {
                requestAndFollowUserLocation(using: nil, fixedScale: true)
            }
        )
    }

    /// 시간선 창을 진단에 남긴다(확대 단계·손잡이·「현재 위치」 확인용).
    private func recordTimelineWindow(_ source: String) {
        MapHomeTimelineWindowRecord.write(
            source: source, startMinute: timeSidebarVisibleStartMinute,
            durationMinutes: timeSidebarVisibleDurationMinutes, selectedMinute: selectedTimelineMinute
        )
    }

    private func requestAndFollowUserLocation(using proxy: MapProxy?, fixedScale: Bool = false) {
        // 현재 위치로 가면 재생을 취소한다. 두 레이아웃의 위치 단추가 모두 여기를
        // 지나므로 한 곳에서 처리한다(대표 요청, 2026-10-26).
        cancelDayPlaybackIfRunning()
        recordTimelineWindow("recenter_before")
        // 지도만 지금으로 옮기고 시간선은 보던 시각에 두면, 확대해 둔 사이드바가
        // 지금과 다른 시각을 가리킨다. 날짜와 선택을 함께 지금으로 되돌린다
        // (대표 지적, 2026-10-27). 날짜를 오늘로 맞추는 일도 여기서만 한다.
        let now = Date()
        if !Calendar.autoupdatingCurrent.isDate(model.selectedDate, inSameDayAs: now) {
            model.selectedDate = now
        }
        if isTimelineSelectionPinned || selectedTimelineMinute != nil {
            selectedTimelineMinute = nil
            isTimelineSelectionPinned = false
        }
        recordTimelineWindow("recenter_after")
        // 위치 버튼으로 다시 따라가기 시작하면 자동 줌 일시 정지를 푼다.
        liveZoomGovernor.reset()
        // 배율 80으로 맞추는 버튼이므로 속도 비례 자동 줌이 곧바로 배율을 덮어쓰지 않게 잠시 멈춘다.
        if fixedScale {
            liveZoomGovernor.pauseForUserAdjustment(uptime: ProcessInfo.processInfo.systemUptime)
        }
        hasCancelledInitialLocationFocus = false
        setUserTrackingMode(.locating)
        // GPS를 기다리는 동안에도 가장 최근 위치로 먼저 이동해 화랑이를 보여준다.
        // 배율 80 고정이면 어느 단계에서도 현재 배율을 그대로 쓰지 않는다.
        if fixedScale {
            focusCurrentLocationAtFixedScale()
        } else {
            focusUserLocation(using: proxy, preservesCamera: true)
        }
        currentLocationRequestTask?.cancel()
        currentLocationRequestTask = Task { @MainActor in
            defer { currentLocationRequestTask = nil }
            let isAvailable = await model.requestMapCurrentLocation(
                requiresFreshReading: true
            )
            guard !Task.isCancelled,
                  userTrackingMode.keepsCameraLocked else { return }
            guard isAvailable || liveFocusCoordinate != nil else {
                setUserTrackingMode(.idle)
                return
            }
            if isAvailable { setUserTrackingMode(.following) }
            if fixedScale {
                focusCurrentLocationAtFixedScale()
            } else {
                focusUserLocation(using: proxy, preservesCamera: true)
            }
        }
    }

    private func toggleMapHeadingMode(using proxy: MapProxy? = nil) {
        compassControlState = compassControlState.toggled
        if compassControlState.followsHeading {
            headingMonitor.start()
            applyMapHeading(using: proxy)
        } else {
            headingMonitor.stop()
            focusUserLocation(
                using: proxy,
                heading: compassControlState.mapCameraHeading,
                preservesCamera: true
            )
        }
    }

    private func applyMapHeading(using proxy: MapProxy?) {
        guard isHeadingMode else { return }
        let heading = headingMonitor.headingDegrees
            ?? visibleMapCamera?.heading
            ?? 0
        if currentCoordinate != nil {
            focusUserLocation(
                using: proxy,
                heading: heading,
                preservesCamera: true
            )
            setUserTrackingMode(.following)
        } else {
            requestAppleMapHeading(heading, centeredAt: nil)
        }
    }

    private func applyInitialLocationIfAvailable(using proxy: MapProxy?) {
        guard MapHomePlaybackCameraPolicy.allowsInitialFocus(
            isPlaybackRunning: isDayPlaybackRunning
        ),
              mapViewportSize.width > 0,
              mapViewportSize.height > 0,
              !hasAppliedInitialLocation,
              !hasAppliedInitialMapFocus,
              currentCoordinate != nil else { return }
        applyInitialMapFocusIfNeeded()
    }

    private func beginInitialLocationRequest(using proxy: MapProxy?) {
        guard MapHomePlaybackCameraPolicy.allowsInitialFocus(
            isPlaybackRunning: isDayPlaybackRunning
        ),
              mapViewportSize.width > 0,
              mapViewportSize.height > 0,
              !hasAppliedInitialMapFocus, model.permissionState(for: .location).isGranted || FirstRunTutorialStore().allowsUnaskedPermissionPrompts,
              initialLocationRequestTask == nil else { return }
        initialLocationRequestTask = Task { @MainActor in
            defer { initialLocationRequestTask = nil }
            let isAvailable = await model.requestMapCurrentLocation(
                requiresFreshReading: true
            )
            guard !Task.isCancelled,
                  isAvailable,
                  !hasCancelledInitialLocationFocus,
                  !hasAppliedInitialMapFocus,
                  MapHomePlaybackCameraPolicy.allowsInitialFocus(
                      isPlaybackRunning: isDayPlaybackRunning
                  ),
                  userTrackingMode == .idle else {
                return
            }
            applyInitialMapFocusIfNeeded()
        }
    }

    private func setUserTrackingMode(_ mode: MapHomeUserTrackingMode) {
        guard userTrackingModeRawValue != mode.rawValue else { return }
        userTrackingModeRawValue = mode.rawValue
    }

    private func handleUserMapPan() {
        MapHomeInteractionMonitor.shared.begin("map_gesture", idleTimeout: 0.5)
        // 재생 중 지도를 직접 끌면 재생을 취소하고 시작 전 시각으로 되돌린다.
        cancelDayPlaybackIfRunning()
        recordUserMapAdjustment()
        setUserTrackingMode(.idle)
        isMapCenteredOnUser = false
    }

    private func handleUserCameraGesture() {
        MapHomeInteractionMonitor.shared.begin("map_gesture", idleTimeout: 0.5)
        // 확대·축소·회전도 지도를 옮기는 손짓이라 재생을 취소한다(대표 요청).
        cancelDayPlaybackIfRunning()
        recordUserMapAdjustment()
    }

    private func recordUserMapAdjustment() {
        liveZoomGovernor.pauseForUserAdjustment(
            uptime: ProcessInfo.processInfo.systemUptime
        )
        hasUserAdjustedMap = true
        hasCancelledInitialLocationFocus = true
        initialLocationRequestTask?.cancel()
        initialLocationRequestTask = nil
        currentLocationRequestTask?.cancel()
        currentLocationRequestTask = nil
        appleViewportCommand = nil
    }

    @discardableResult
    private func updateUserCenterState(using proxy: MapProxy?) -> Bool {
        let point: CGPoint?
        if let proxy, let coordinate = displayedLocationCoordinate {
            point = proxy.convert(coordinate, to: .named("mapHomeViewport"))
        } else {
            point = vectorMapViewportStore.viewport?
                .markerPoints[vectorDisplayedMarkerID]
        }
        return updateUserCenterState(locationPoint: point)
    }

    @discardableResult
    private func updateUserCenterState(locationPoint: CGPoint?) -> Bool {
        let nextValue = locationPoint.map {
            MapHomeCameraLayoutMath.isCentered(
                locationPoint: $0,
                targetPoint: currentLocationTargetPoint
            )
        } ?? false
        if isMapCenteredOnUser != nextValue {
            isMapCenteredOnUser = nextValue
        }
        return nextValue
    }

    private func updateVisibleMapSpan(_ span: MKCoordinateSpan) {
        let next = MKCoordinateSpan(
            latitudeDelta: min(max(span.latitudeDelta, 0.000_001), 180),
            longitudeDelta: min(max(span.longitudeDelta, 0.000_001), 360)
        )
        guard abs(visibleMapSpan.latitudeDelta - next.latitudeDelta) > 0.000_1
            || abs(visibleMapSpan.longitudeDelta - next.longitudeDelta) > 0.000_1
        else { return }
        visibleMapSpan = next
    }

    private func applyMapCameraFrame(
        _ frame: MapHomeCameraFrame,
        using proxy: MapProxy
    ) {
        let locationPoint = displayedLocationCoordinate.flatMap {
            proxy.convert($0, to: .named("mapHomeViewport"))
        }
        applyMapCameraFrame(frame, locationPoint: locationPoint)
    }

    private func applyMapCameraFrame(
        _ frame: MapHomeCameraFrame,
        locationPoint: CGPoint?
    ) {
        if let locationPoint {
            submitDisplayedStickmanViewportPoint(locationPoint)
        } else if displayedLocationCoordinate == nil {
            displayedStickmanViewportPoint = nil
        }
        if visibleMapCamera != frame.camera {
            visibleMapCamera = frame.camera
        }
        if visibleMapCenter.latitude != frame.centerLatitude
            || visibleMapCenter.longitude != frame.centerLongitude {
            visibleMapCenter = frame.center
        }
        updateVisibleMapSpan(frame.span)
        let isCentered = updateUserCenterState(locationPoint: locationPoint)
        if userTrackingMode == .locating, isCentered {
            setUserTrackingMode(.following)
        }
        if let level = sharedZoomLevel(for: frame.span),
           abs(level - sharedZoomLevel) > 0.02 {
            sharedZoomLevel = level
        }
    }

    private func submitDisplayedStickmanViewportPoint(_ point: CGPoint) {
        guard let rendered = stickmanViewportProjection.submit(
            point,
            nowUptime: ProcessInfo.processInfo.systemUptime
        ) else { return }
        displayedStickmanViewportPoint = rendered
    }

    private func finishDisplayedStickmanViewportProjection() {
        guard let rendered = stickmanViewportProjection.finish(
            nowUptime: ProcessInfo.processInfo.systemUptime
        ) else { return }
        displayedStickmanViewportPoint = rendered
    }

    private func flushMapCameraFrame(using proxy: MapProxy) {
        guard let frame = mapCameraFrameProjection.finish(
            nowUptime: ProcessInfo.processInfo.systemUptime
        ) else { return }
        applyMapCameraFrame(frame, using: proxy)
    }

    private func isValid(_ point: GeoPoint) -> Bool {
        (-90...90).contains(point.latitude)
            && (-180...180).contains(point.longitude)
            && point.horizontalAccuracy >= 0
    }
}
