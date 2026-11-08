import CoreLocation
import MapKit
import Observation
import OSLog
import SwiftUI
import UIKit
import TaptionPlanCore

extension MapHomeView {
    /// 지도 위에 그리는 것들을 한 그룹으로 묶는다.
    var mapDisplayGroup: some View {
        VStack(alignment: .leading, spacing: 0) {
            displayGroupHeader(language.text("지도", "Map"), systemImage: "map", isExpanded: $isMapGroupExpanded)
            if isMapGroupExpanded {
                displayToggle(language.text("경로", "Routes"), systemImage: "point.topleft.down.to.point.bottomright.curvepath", isOn: $showsRoutesOnMap)
                displayToggle(language.text("발자국", "Footprints"), systemImage: "pawprint.fill", isOn: $showsFootprintsOnMap)
                displayToggle(language.text("사진(지도)", "Photos (map)"), systemImage: "photo.fill", isOn: $showsPhotosOnMap)
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
    var counterMenuItem: some View {
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

    func counterBinding(_ kind: MapHomeCounterKind) -> Binding<Bool> {
        Binding(
            get: { isCounterOn(kind) },
            set: { setCounter(kind, isOn: $0) }
        )
    }

    func isCounterOn(_ kind: MapHomeCounterKind) -> Bool {
        switch kind {
        case .steps: showsStepCounter
        case .distance: showsDistanceCounter
        case .work: showsWorkCounter
        case .study: showsStudyCounter
        case .hobby: showsHobbyCounter
        case .exercise: showsExerciseCounter
        }
    }

    func setCounter(_ kind: MapHomeCounterKind, isOn: Bool) {
        switch kind {
        case .steps: showsStepCounter = isOn
        case .distance: showsDistanceCounter = isOn
        case .work: showsWorkCounter = isOn
        case .study: showsStudyCounter = isOn
        case .hobby: showsHobbyCounter = isOn
        case .exercise: showsExerciseCounter = isOn
        }
    }

    var enabledCounterKinds: [MapHomeCounterKind] {
        MapHomeCounterKind.allCases.filter { isCounterOn($0) }
    }

    var settingsMenuItem: some View {
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
                .modifier(MapHomeMenuRowPadding())
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

                FirstRunPermissionSettingsRow(model: model, language: language).padding(.leading, 12)

                FirstRunTutorialReplayRow(model: model, language: language).padding(.leading, 12)

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

    var proMenuTitle: String {
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

    var gpsLoggingMenuItem: some View {
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
                ) { seconds in
                    GPSLoggingBatteryIcon(seconds: seconds, tint: tint)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
        }
    }

    func gpsLoggingIntervalText(_ seconds: Int) -> String {
        let interval = GPSLoggingPreferences.intervalText(seconds)
        return language.text(
            "\(interval)마다 위치 확인",
            "Checks location every \(interval)"
        )
    }

    @ViewBuilder
    func menuItem(_ icon: String, _ title: String, isSelected: Bool = false, action: @escaping () -> Void) -> some View {
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

    var isDisplayedCatAtHome: Bool {
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

    /// 표시 전용 하루 기록(카운터·요약). 오늘은 기록이 쌓일 때마다 revision이 올라 `currentDayDataSnapshot`이 순간순간 nil이 되고,
    /// 그때마다 카운터 합계가 0으로 떨어져 업무시간 카운터가 사라졌다 생겼다 했다. 낡았어도 같은 날의 마지막 기록을 쓴다(대표 지적, ARC1030A07).
    var displayDayDataSnapshot: PlanDayDataSnapshot? {
        if let current = currentDayDataSnapshot { return current }
        guard let dayDataSnapshot,
              dayDataSnapshot.projectionVersion == TaptionPlanV3Store.projectionVersion,
              Calendar.autoupdatingCurrent.isDate(dayDataSnapshot.day, inSameDayAs: model.selectedDate) else { return nil }
        return dayDataSnapshot
    }

    var displayedExpectedRouteOverlays: [MapHomeExpectedRouteOverlay] {
        Array(
            visibleExpectedRouteOverlays.prefix(
                MapHomeForecastRouteDisplayPolicy.maximumVisibleRoutes
            )
        )
    }

    var displayedWBSGeneratedRouteOverlays: [MapHomeWBSGeneratedRouteOverlay] {
        let remaining = max(
            0,
            MapHomeForecastRouteDisplayPolicy.maximumVisibleRoutes
                - displayedExpectedRouteOverlays.count
        )
        return Array(visibleWBSGeneratedRouteOverlays.prefix(remaining))
    }

    var displayedPlaybackFocusPoint: GeoPoint? {
        displayedPlaybackLocation?.cameraCoordinate
    }

    var displayedPlaybackLocation: MapHomePlaybackLocation? {
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
        ) ?? MapHomePlaybackLocation.restingLocation(
            at: displayedLocationDate,
            normalizedReadings: historicalPlaybackReadings,
            places: currentDayDataSnapshot?.places ?? [],
            sleepSpans: model.sleepSessions.map(\.span) + (currentDayDataSnapshot?.actuals ?? []).filter(AutomaticRecordTimelineEngine.isSleep).map { $0.span(asOf: .now) },
            home: model.settings.frequentPlaces.first { $0.kind == .home }?.point
        )
    }

    var displayedLocationCoordinate: CLLocationCoordinate2D? {
        let isToday = Calendar.autoupdatingCurrent.isDateInToday(model.selectedDate)
        // GPS가 끊겨도 오늘은 화랑이를 마지막 위치에 둔다.
        if selectedTimelineMinute != nil { return historicalPlaybackCoordinate ?? (isToday ? lastKnownCoordinate : nil) }
        return isToday ? liveFocusCoordinate : nil
    }

    var displayedPlaybackMinute: Double? {
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

    var displayedPlaybackDate: Date? {
        displayedPlaybackMinute.map(timelineDate(forMinute:))
    }

    var displayedLocationDate: Date {
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
    var displayedSpeedMetersPerSecond: Double? {
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
    var displayedStickmanAction: MapHomeStickmanAction {
        let probe = MapHomePlaybackProbe.begin("stickmanAction"); defer { MapHomePlaybackProbe.end(probe) }
        let key = MapHomeStickmanActionKey(
            second: Int(displayedLocationDate.timeIntervalSinceReferenceDate),
            sourceRevision: currentDayDataSnapshot?.sourceRevision,
            sleepCount: model.sleepSessions.count,
            frequentPlaceCount: model.settings.frequentPlaces.count,
            legCount: wbsPlaybackProjection?.legs.count ?? 0,
            expectedCount: expectedRouteOverlays.count,
            latestID: model.latestSensorReading?.id,
            hasSelection: selectedTimelineMinute != nil,
            calendarEventCount: model.snapshot.calendarEvents.count
        )
        return stickmanActionMemo.value(for: key) { computeDisplayedStickmanAction() }
    }

    func computeDisplayedStickmanAction() -> MapHomeStickmanAction {
        MapHomeMeetingPolicy.action(
            computeRecordedStickmanAction(),
            at: displayedLocationDate,
            events: model.snapshot.calendarEvents,
            travel: currentDayDataSnapshot?.travel ?? []
        )
    }

    var displayedLocationAccessibilityLabel: String {
        if wbsPlaybackFrame?.routePhase == .forecast
            || expectedRoutePlaybackCoordinate != nil {
            return language.text("예상 경로 위치", "Expected route location")
        }
        return historicalPlaybackCoordinate == nil
            ? language.text("현재 위치", "Current location")
            : historicalPlaybackAccessibilityLabel
    }

    /// 날씨 표시 값. `onChange(of: model.snapshot.weather)`가 이미 합쳐 두므로 본문에서 다시 합치지 않는다.
    /// 예전에는 화면이 그려질 때마다 최대 512개를 다시 합쳐 재생 중 메인 스레드의 15%를 썼다(ARC1030A01).
    var displayWeatherContexts: [WeatherContext] {
        cachedWeatherContexts.isEmpty ? model.snapshot.weather : cachedWeatherContexts
    }

    func focusDisplayedLocation(using proxy: MapProxy?) {
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

    func submitDisplayedStickmanViewportPoint(_ point: CGPoint) {
        guard let rendered = stickmanViewportProjection.submit(
            point,
            nowUptime: ProcessInfo.processInfo.systemUptime
        ) else { return }
        displayedStickmanViewportPoint = rendered
    }

    func finishDisplayedStickmanViewportProjection() {
        guard let rendered = stickmanViewportProjection.finish(
            nowUptime: ProcessInfo.processInfo.systemUptime
        ) else { return }
        displayedStickmanViewportPoint = rendered
    }
}
