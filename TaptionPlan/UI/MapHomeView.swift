import CoreLocation
import MapKit
import Observation
import OSLog
import SwiftUI
import UIKit
import TaptionPlanCore

@MainActor
struct MapHomeView: View {
    static let dayViewSignpostLog = OSLog(
        subsystem: "com.taption.plan",
        category: .pointsOfInterest
    )

    @Environment(\.scenePhase) var scenePhase

    @Bindable var model: AppModel

    @Bindable var proAccess: TaptionProAccessController

    let onInitialDataReady: () -> Void

    @State var mapPosition: MapCameraPosition = .automatic

    @State var mapCameraRevision = 0

    @State var appleViewportCommand: MapHomeAppleViewportCommand?

    @State var vectorMapViewportStore = MapHomeVectorViewportStore()

    @State var isMenuOpen = false

    @State var isDateWeekExpanded = false

    @State var isCalendarPresented = false

    @State var selectedLocationDestination: MapHomeLocationDestination?

    @State var isTransitLocationsPresented = false

    @State var isLocationMenuExpanded = false

    @State var isUserLocationsMenuExpanded = false

    @State var isCategoryMenuExpanded = false

    @State var expandedCategoryDetails: Set<String> = []

    @State var isCategoryAddPresented = false
    @State var editingUserCategory: MapUserActivityCategory?

    @State var isDisplayMenuExpanded = false

    @State var isCounterMenuExpanded = false

    @State var isSidebarGroupExpanded = false

    @State var isMapGroupExpanded = false

    @AppStorage(MapHomeStickmanAction.vehicleDisplayKey) var showsVehicleRides = true

    /// 화랑이 위 카운터 위젯이 지도 화면 좌표에서 차지하는 영역. 위젯을 누르면 카운터 메뉴를 연다(ARC1030A11).
    @State var counterWindowFrame = MapHomeCounterFrameBox()

    /// 카운터 창 줄을 위에서 아래 순서로 늘어놓은 목록. 창을 눌렀을 때 몇 번째 줄인지 이 순서로 고른다.
    @State var counterRowTargets: [MapHomeCounterDetailTarget] = []

    /// 지금 열려 있는 카운터 상세 화면.
    @State var counterDetail: MapHomeCounterDetailTarget?

    /// 상세 화면은 연 순간의 값으로 만든다. 부모 본문이 다시 계산돼도 되풀이하지 않는다(SHT1102A01).
    @State var counterDetailSnapshot = MapHomeCounterDetailSnapshot()

    /// 지도 뷰의 뷰포트 공간 프레임. 지도는 위 안전 영역까지 덮어 뷰포트보다 위에서 시작하므로(18 Pro Max에서 62pt), 지도 안 점과 뷰포트 탭을 이 원점으로 맞춘다.
    @State var mapFrameInViewport = CGRect.zero

    @State var isStrideCalibrationPresented = false

    @State var isSalarySettingsPresented = false

    @State var isCarAudioSheetPresented = false
    @State var isShortcutsGuidePresented = false

    @AppStorage(MapHomeSalaryPolicy.annualKey) var salaryAnnualPay = 0.0
    @AppStorage(MapHomeAllowancePolicy.isSelectedKey) var allowanceIsSelected = false

    @AppStorage(MapHomeSalaryPolicy.monthlyPayKey) var salaryMonthlyPay = 0.0

    @AppStorage(MapHomeSalaryPolicy.isNetInputKey) var salaryIsNetInput = false

    @AppStorage(MapHomeSalaryPolicy.showsNetKey) var salaryShowsNet = true

    @AppStorage(MapHomeSalaryPolicy.monthAccumKey) var salaryMonthAccum = 0.0

    @AppStorage(MapHomeSalaryPolicy.payHistoryKey) var salaryPayHistoryRaw = ""

    @AppStorage(MapHomeSalaryPolicy.tickKey) var salaryTickSeconds = 10

    @State var salaryLive: MapHomeSalaryPolicy.Live?

    /// 날짜(0시)별 업무 구간. 선택한 날짜와 오늘만 둔다.
    @State var salaryWorkSpans: [Date: [TimeSpan]] = [:]

    @State var queueExpanded = false

    @State var memoStackExpanded = false

    @State var todayCalendarExpanded = false

    @State var topPanelOrder: [TopPanel] = []

    /// 선택한 날의 일정(구글 계정 연결 시 구글, 아니면 기기 캘린더). 시작 시간에 구글 로고로 표시한다.
    @State var dayCalendarEvents: [CalendarRecord] = []

    /// `dayCalendarEvents`가 어느 날짜의 목록인지. 날짜를 바꾼 직후 이전 날 목록이 남지 않게 한다.
    @State var dayCalendarEventsDate: Date?

    /// 오른쪽 사이드바(시간·날씨 띠) 전체를 켜고 끈다. 날짜 배지 아래 원형 버튼으로 바꾼다.
    @AppStorage("mapHomeSidebarVisible") var isSidebarVisible = true

    /// 일정을 읽지 못한 이유. 있으면 구글 캘린더 버튼이 목록 대신 고칠 수 있는 설정을 연다.
    @State var calendarAccessProblem: MapHomeCalendarAccessProblem?

    /// 선택한 날의 시간 메모 캐시(배지 계산용).
    @State var timedMemoCache: [ActionMemo] = []

    /// 날짜 줄을 끄는 동안 손가락을 따라 움직이는 거리(한 칸을 넘지 않는다).
    /// 시작 시간 제한이 지났는지(DB나 경로가 끝나지 않아도 홈을 연다).
    @State var initialReadyForced = false

    @State var calendarService = AppleCalendarService()

    @State var isHomeMissingAlertPresented = false

    @State var isPlacingMapMemo = false

    @State var dismissedMemoPreviewIDs = Set<UUID>()

    let isStickerMode = true

    @State var selectedMapStickerEditor: MapHomeStickerEditorTarget?

    @State var sidebarNote: MapHomeSidebarNote?

    @State var isSettingsMenuExpanded = false


    @State var isDataProtectionPresented = false

    @State var isSettingsResetConfirmationPresented = false

    @AppStorage(
        AppLanguagePreference.sharedDefaultsKey,
        store: UserDefaults(suiteName: AppLanguagePreference.appGroupIdentifier)
    ) var languageRawValue = AppLanguagePreference.current.rawValue

    @AppStorage(MapHomePlaybackZoomMode.storageKey)
    var playbackZoomModeRaw = MapHomePlaybackZoomMode.adaptive.rawValue

    @AppStorage(MapHomeLayoutStyle.storageKey)
    var layoutStyleRaw = MapHomeLayoutStyle.classic.rawValue

    @AppStorage(MapHomeRecordingLayers.storageKey)
    var recordingLayersRaw = ""

    @State var isScreenRecording = false
    /// 듀오 바깥 화면의 오른쪽 상태 줄 폭. 0이면 보통 화면(DUO1111A03).
    @State var duoStatusColumn: CGFloat = 0

    @State var photoMoments: [PhotoMoment] = []

    @State var photosNeedReadingRetry = false

    @AppStorage("mapHomeShowsPhotos") var showsPhotosOnMap = true
    /// 하단 사진링을 아래로 끌어 반달로 접었다(RNG1106A01). 사이드바와 무관하게 유지한다.
    /// 하단 사진링은 늘 쓰며 처음엔 `집` 위 반달로 접혀 있다(RNG1108A01, 대표 지시: 메뉴 켜기 대신 반달).
    @State var isPhotoRingFolded = true

    /// 표시 메뉴의 경로·발자국 켜기/끄기(대표 지시, ARC1030A06). 녹화 레이어와는 별개로, 평소 화면에 적용된다.
    @AppStorage("mapHomeShowsRoutes") var showsRoutesOnMap = true

    @AppStorage("mapHomeShowsFootprints") var showsFootprintsOnMap = true

    @AppStorage(MapHomeSidebarTimeFormat.storageKey) var sidebarTimeFormatRaw = MapHomeSidebarTimeFormat.twentyFourHour.rawValue


    @AppStorage("mapHomeMemoDisplay") var memoDisplayRaw = MapHomeMemoDisplayMode.all.rawValue

    // 표시 > 카운터에서 켜고 끄는 카운터. 연봉 카운터만 따로 설정 화면을 갖는다.
    @AppStorage(MapHomeCounterKind.steps.storageKey) var showsStepCounter = true

    @AppStorage(MapHomeCounterKind.distance.storageKey) var showsDistanceCounter = true

    @AppStorage(MapHomeCounterKind.work.storageKey) var showsWorkCounter = true

    @AppStorage(MapHomeCounterKind.study.storageKey) var showsStudyCounter = true

    @AppStorage(MapHomeCounterKind.hobby.storageKey) var showsHobbyCounter = true

    @AppStorage(MapHomeCounterKind.exercise.storageKey) var showsExerciseCounter = true
    @AppStorage(MapHomeCounterKind.spending.storageKey) var showsSpendingCounter = true

    @AppStorage("mapHomeCounter.salary") var showsSalaryCounter = true

    @AppStorage("mapHomeCounter.collapsed") var isCounterCollapsed = false

    @State var isCalendarConnectPresented = false

    @State var pendingMemoLocationID: UUID?

    @State var isMapAttributionPresented = false

    @State var isAlarmSettingsPresented = false

    @State var pendingAlarm: (kind: MapHomeAlarmKind, at: Date)?

    @State var isDailyCardPresented = false

    /// 땅은 벡터 지도에서만 그려져서, 붙일 타일이 있고 집 근처로 확대하면 벡터 스타일로 자동 전환했다가 끝나면 되돌린다.
    @AppStorage("mapHomeAutoLandStyle") var autoLandStyleEnabled = true

    /// "원래 스타일|자동 전환한 스타일". 비어 있으면 자동 전환 중이 아니다.
    @AppStorage("mapHomeAutoLandStyleState") var autoLandStyleState = ""

    @State var photoClusterCache = MapHomePhotoClusterCache()

    @State var photoBrowserSelection: MapHomePhotoBrowserSelection?

    let photoLibrary = ApplePhotoLibraryService()

    @State var isRecordingOptionsPresented = false

    @State var isPlaybackVideoPresented = false

    @State var recordedVideoShare: URL?

    @State var recordingFailureMessage: String?

    @State var screenRecorder = MapHomeScreenRecorder()

    @AppStorage(MapHomeGrowthPolicy.storageKey)
    var homeGrowthData = Data()

    @State var growthHistoryCache = MapHomeGrowthHistoryCache()

    @State var compassControlState: MapHomeCompassControlState = .directionArrow

    @State var headingMonitor = MapHomeHeadingMonitor()

    @State var selectedScope: TimeScale = .day

    @State var playbackProgress = MapHomePlaybackProgress()

    @State var selectedPawprintTimestamp: Date?

    /// 발자국을 누르면 강조하는 발자국의 시각. 재생·시간 조정으로 지워지는 선택과 따로 둔다.
    @State var highlightedPawprintTimestamp: Date?

    @State var selectedPawprintCoordinate: CLLocationCoordinate2D?

    @State var isTimelineSelectionPinned = false

    @State var sectionEditSelection: MapHomeSectionEditSelection?

    @State var isUnconfirmedReviewPresented = false
    /// 앱을 열 때 묻는 질문 하나와, 이번에 이미 물은 것(ASK1111A01).
    @State var launchPrompt: MapHomeLaunchPrompt?

    @State var focusedUnconfirmedReviewSegment: MapHomeTimeRailSegment?

    @State var pendingUnconfirmedEditMinute: Int?

    @State var isMapCenteredOnUser = false

    @SceneStorage("MapHome.userTrackingMode")
    var userTrackingModeRawValue = MapHomeUserTrackingMode.idle.rawValue

    /// 본문이 읽지 않는 작업 핸들·세대 번호·시각(ARC1103A01 안 6). 바뀌어도 화면을 무효화하지 않는다.
    @State var work = MapHomeViewWork()

    @State var hasAppliedInitialLocation = false

    @State var hasAppliedInitialMapFocus = false

    @State var startupCameraPolicy = MapHomeStartupCameraPolicy()

    @State var hasCancelledInitialLocationFocus = false

    @State var mapSearchText = ""

    @State var mapSearchResults: [MapHomeSearchResult] = []
    /// 검색 결과가 없거나 실패했을 때 목록 자리에 보일 한 줄(SRC1107A01).
    @State var mapSearchNotice: String?

    @State var selectedSearchPin: MapHomeSearchResult?

    @State var isSearchPinMenuPresented = false

    @State var selectedMarkerInfo: MapHomeMarkerInfoKind?

    /// 랜드마크 시트가 등록지점(집·회사·식당 등)을 고칠 수 있도록 누른 장소 id를 함께 든다.
    @State var selectedMarkerPlaceID: UUID?

    /// 등록 위치의 범위(주황·빨강 원) 표시 여부. 랜드마크 시트에서 켜고 끈다.
    @AppStorage(MapHomePlaceRangeEditor.showsRangeKey) var showsPlaceRanges = true

    /// 안개 탐험 강도. 앱을 다시 열어도 고른 세기가 남는다.
    @AppStorage(MapHomeFogStrength.storageKey) var fogStrengthRaw = MapHomeFogStrength.light.rawValue

    @State var isLongPressMenuPresented = false

    @State var isDaySummaryPresented = false

    /// 하루 요약을 화랑이에서 열었는지. 열려 있는 동안 카메라 맞춤의 기준이 집 대신 화랑이가 된다.
    @State var daySummaryFocusesCat = false

    /// 하루요약 시트 높이. 접으면 화면 절반, 위로 펼치면 지금의 전체 화면이다.
    @State var daySummaryDetent: PresentationDetent = MapHomeDaySummarySheet.collapsedDetent

    /// 지도 카메라에 이미 반영한 "시트가 덮은 비율". 0이면 지도 전체가 보이는 상태다.
    @State var daySummaryAppliedCoverage: CGFloat = 0

    @State var pendingLongPressCoordinate: CLLocationCoordinate2D?

    @State var requestingPermission: RequiredPermission?

    @State var selectedUserLocation: MapHomeUserLocationSelection?

    @State var selectedTransitBoardingCandidate: TransitBoardingCandidate?

    @State var selectedPredictedRoute: MapPredictedRoute?

    @State var pendingUserLocationSelection: MapHomeUserLocationSelection?

    @State var nearbyTransitPlaces: [TransitBoardingPlace] = []

    @State var transitBoardingReadingsRevision: UInt64 = 0

    @State var nearbyTransitPlacesRevision: UInt64 = 0

    @State var mapSearchCompleter = MapHomeSearchCompleter()

    @FocusState var isMapSearchFocused: Bool

    @State var isSearchExpanded = false

    @State var visibleMapCenter = CLLocationCoordinate2D(latitude: 0, longitude: 0)

    @State var timeRailSegments: [MapHomeTimeRailSegment] = []

    @State var routeProjection: RouteTimelineProjection?

    /// 마지막 경로 계산의 입력 요약. 같으면 다시 계산하지 않는다.
    @State var routeProjectionInputKey: RouteProjectionInputKey?

    /// 발자국 장부 캐시. 기록이 늘 때만 새로 만든다(ARC1030A07).
    @State var pawprintLedgerMemo = MapHomeMemo<MapHomePawprintLedgerKey, [MapHomePawprintLedger.Entry]>()

    @State var pawprintWaypointsMemo = MapHomeMemo<MapHomePawprintWaypointsKey, [PawprintWaypoint]>()

    @State var routeProjectionInFlight = false

    @State var routeProjectionDirty = false

    @State var routeActualIndex: RouteTimelineDataEngine.ActualIndex?

    @State var wbsPlaybackProjection: MapHomeWBSPlaybackProjection?

    @State var dayDataSnapshot: PlanDayDataSnapshot?

    @State var dayDataIsPreview = false

    @State var hasDeferredWBSPlaybackRefresh = false

    @State var routeReadings: [SensorReading] = []

    @State var routeReadingsLoadState: MapHomeRouteReadingsLoadState = .idle

    @State var hasReportedInitialDataReady = false

    @State var normalizedRouteReadings: [SensorReading] = []

    @State var currentMapLocationReading: SensorReading?

    @State var historicalPlaybackReadings: [SensorReading] = []

    @State var displayRouteReadings: [SensorReading] = []

    @State var lastPreparedRouteReadingsSignature: String?

    @State var timelineRouteOverlays: [MapHomeTimelineRouteOverlay] = []

    @State var cachedTemporaryLocations: [SubwayStationCatalog.TemporaryLocation] = []

    @State var expectedRouteOverlays: [MapHomeExpectedRouteOverlay] = []

    @State var wbsGeneratedRouteOverlays: [MapHomeWBSGeneratedRouteOverlay] = []

    @State var pendingForecastRouteState: MapHomeForecastRouteState?

    @State var expectedRouteCache: [ExpectedRouteRequest: [CLLocationCoordinate2D]] = [:]

    @State var wbsExpectedRouteRequests: [ExpectedRouteRequest] = []

    @State var wbsExpectedRouteRequestsInputKey: MapHomeExpectedRouteInputKey?

    @State var visibleMapSpan = MKCoordinateSpan(
        latitudeDelta: 0.025,
        longitudeDelta: 0.035
    )

    @State var sharedZoomLevel: CGFloat = 1

    @State var zoomResetToken = 0

    /// 시간선 확대·축소 단추가 올리는 값. 레일은 이 값의 변화량만큼 단계를 밟는다.
    @State var zoomStepToken = 0

    /// 시간선이 보이는 창(시작 분·길이). 시간 레일·날씨 띠·선택 캡슐이 이 값 하나를
    /// 함께 쓴다. 두 벌로 두면 한쪽만 되돌아가 두 시간축이 어긋난다(2026-10-27).
    @State var timeSidebarVisibleStartMinute = 0

    @State var timeSidebarVisibleDurationMinutes = MapHomeTimeSidebarMath.fullDayMinutes

    @State var cachedWeatherContexts: [WeatherContext]

    @State var activePaletteCategoryID: String?

    @State var customPaletteColor = Color.tpReferenceMint

    @State var mapCameraFrameProjection = MapHomeCameraFrameProjection()

    @State var mapRenderCache = MapHomeMapRenderCache()

    @State var liveZoomGovernor = MapHomeLiveZoomGovernor()

    @State var playbackZoomSmoother = MapHomePlaybackZoomSmoother()

    @State var playbackZoomPlan = MapHomePlaybackZoomPlan(inputs: [])

    @State var visibleMapCamera: MapCamera?

    @State var shouldFitRoutesAfterDateChange = false

    @State var hasUserAdjustedMap = false

    @State var stickmanViewportProjection = MapHomeStickmanViewportProjection()

    @State var displayedStickmanViewportPoint: CGPoint?

    /// Apple 지도가 움직이는 동안 프레임마다 받은 화랑이 점(관찰 안 함)과 "움직이는 중" 표시.
    /// 카운터 창은 움직이는 동안 이 상자를 화면 틱마다 읽고, 관찰 값은 읽기 값 간격과 손을 뗄 때만 따라온다(UIX1031A06).
    @State var appleStickmanLivePoint = MapHomeAppleStickmanLivePoint()

    @State var isAppleCameraMoving = false

    @State var mapViewportSize = CGSize.zero

    @State var headerFrame = CGRect.zero

    @State var searchFieldFrame = CGRect.zero

    @State var mapControlsFrame = CGRect.zero

    @State var isDayPlaybackRunning = false

    @State var counterValueCache = MapHomeCounterValueCache()

    @State var counterBadgeThrottle = MapHomeCounterBadgeThrottle()

    @State var isTimelineInteractionActive = false

    @State var routeDocumentProjectionGate = MapHomeRouteDocumentProjectionGate()

    @State var isPlaybackIntroActive = false

    @State var playbackClock = MapHomePlaybackClock()

    @State var dayReadingsCache = MapHomeDayReadingsCache()

    @State var temporaryLocationsMemo = MapHomeMemo<MapHomeReadingsSignature, [SubwayStationCatalog.TemporaryLocation]>()

    @State var predictedGapsMemo = MapHomeMemo<MapHomeReadingsSignature, [MapHomePredictedGPSGap]>()

    @State var subwayOverlayDerived = MapHomeStaleWhileRevalidate<MapHomeReadingsSignature, Int, [MapHomeSubwayRouteOverlay]>()

    @State var derivedUpdateTick = 0

    @State var homeWeatherBadgeMemo = MapHomeMemo<MapHomeHomeWeatherKey, MapHomeHomeWeatherBadge?>()
    /// 수묵 테마 핀 도장: 보고 있는 날 머문 등록 장소 키(INK1108A01).
    @State var placeStampMemo = MapHomeMemo<MapHomePlaceStampKey, Set<String>>()
    @State var isPlaceBookPresented = false
    @State var isPassportPresented = false
    @State var isTravelAddChoicePresented = false
    @State var memoLedgerFilter = LedgerMemoFilter.all
    /// 할 일 목록 패널의 「확인할 것」. 패널을 열 때 읽는다(TDP1113A01).
    @State var todoItems: [MapHomeLaunchPrompt] = []
    @State var memoLedgerLinkedIDs: Set<UUID> = []
    @State var isTripImportPresented = false
    @State var isLocationAlwaysPromptPresented = false
    @State var isTripClipboardOfferVisible = false
    @State var pastedTripText: String?
    /// 메뉴 → AI 비서 화면과 명령 반영 알림(AIR1110A01·TRP1110A07).
    @State var isAssistantPresented = false
    /// 여권 도장을 눌러 나온 쪽. 있으면 왼쪽 위에 돌아가기 단추가 뜬다.
    @State var passportReturnPage: Int?
    @State var passportStartPage = 0
    /// 여행 계획 모드. 미래 날짜만 고른다.
    @State var isTravelMode = false
    /// 여행 모드 화면(TVB1112A01): 지구본과 여행 목록, 여행별 화면.
    @State var isTravelHomePresented = false
    @State var isTravelPlanPresented = false

    @State var stickmanActionMemo = MapHomeMemo<MapHomeStickmanActionKey, MapHomeStickmanAction>()

    @State var meetingRailSpansMemo = MapHomeMemo<String, [Range<Int>]>()

    @State var transitBoardingDerived = MapHomeStaleWhileRevalidate<MapHomeTransitBoardingGroup, Date, [TransitBoardingCandidate]>()

    @State var transitBoardingReadingsMemo = MapHomeMemo<MapHomeReadingsSignature, [SensorReading]>()

    /// 벡터 지도에서는 재생을 구동기가 맡는다(PLY1029A03). Apple 지도는 아직 예전 루프.
    @State var playbackDriver: MapHomePlaybackDriver?

    @State var mapDayCacheWriteSignature: Int?

    static let categoryPaletteHexes = [
        "#8FD9C5", "#A9CFF0", "#A7DDEB", "#C2B4E9",
        "#B8B7E8", "#F2B18D", "#F2A8B8", "#CBD5E1",
        "#F2D58D", "#F28FA9", "#B7DCC7", "#B7D5EE",
    ]

    static let mapCacheAlgorithmKey = "route-document-v10"

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

    var isWideLayout: Bool { MapHomeWideLayoutPolicy.isWide(viewportWidth: mapViewportSize.width) }

    var timeRailWidth: CGFloat { MapHomeWideLayoutPolicy.timeRailWidth(viewportWidth: mapViewportSize.width) }

    /// 측정용: `-autoStartDayPlayback`으로 켜면 지도가 뜬 뒤 재생을 저절로 시작하고 끝나면 로그 패키지를 만든다(PLY1029A08).
    /// 벡터 지도 뷰가 아니라 화면 공통 위치에서 돈다. 지도 스타일을 바꾸면 벡터 지도 뷰가 사라져 안에 둔 작업이 취소됐다(ARC1030A04).
    func runBenchAutoPlayback() async {
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

    var body: some View {
        let probe = MapHomePlaybackProbe.begin("body")
        MapHomePlaybackProbe.inBody = true
        defer { MapHomePlaybackProbe.inBody = false; MapHomePlaybackProbe.end(probe) }
        return lifecycleModifiers(presentationModifiers(baseContent)).mapHomeDebugViewportWidth()
    }

    /// 선택한 날의 시간이 있는 메모(지도 메모 포함). 사이드바에 메모 아이콘으로 기본 표시한다.
    var timedMemosForSelectedDate: [ActionMemo] { memoDisplayMode == .hidden ? [] : timedMemoCache }

    var vectorSearchMarkerID: String { "search-location" }

    /// 땅 한 칸의 실제 크기(m). 최대 확대(카메라 거리 80m, 1점≈0.06m) 기준으로 한 칸이 약 416pt가 된다.
    static let landCellMeters = 25.0

    /// 하단 메뉴 고정: 홈 배치는 하단 탭으로 고정한다(선택 메뉴 제거).
    var layoutStyle: MapHomeLayoutStyle { .tabBar }

    /// 사이드바를 펼치고 접는 튕김. 펼칠 때는 위에서 아래로 쫙 내려오고, 접을 때는 아래부터 위로 줄어든다.
    static let sidebarToggleSpring = Animation.spring(response: 0.5, dampingFraction: 0.62)

    var selectedDaySpan: TimeSpan { MapHomeCounterTimelinePolicy.daySpan(of: model.selectedDate) }
}
