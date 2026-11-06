import CoreLocation
import MapKit
import Observation
import OSLog
import SwiftUI
import UIKit
import TaptionPlanCore

extension MapHomeView {
    /// 안개 탐험에서 걷어낼 지점. 지도 좌표를 화면 좌표로 옮겨 `MapHomeFogLayer`에 넘긴다.
    func fogReveals(
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

        var vectorDisplayedMarkerID: String { "displayed-location" }

    struct PawprintWaypoint: Identifiable {
        let index: Int
        let coordinate: CLLocationCoordinate2D
        let angle: Double
        let isPredicted: Bool
        let timestamp: Date?
        var predictedRoute: MapPredictedRoute? = nil
        var speedMetersPerSecond: Double? = nil
        var id: Int { index }
    }

    func pawprintImage(_ waypoint: PawprintWaypoint) -> some View {
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

    /// 하루 발자국 장부(기록이 늘 때만 다시 만든다). 지하철 구간도 믿을 만한 GPS 발자국은 선 위에 남긴다(MAP1106A01).
    func pawprintLedger() -> [MapHomePawprintLedger.Entry] {
        let readings = currentDayReadings
        let railSpans = MapHomePawprintLedger.railSpans(in: displayDayDataSnapshot?.travel ?? [])
        let key = MapHomePawprintLedgerKey(
            day: Calendar.autoupdatingCurrent.startOfDay(for: model.selectedDate),
            count: readings.count, firstID: readings.first?.id, lastID: readings.last?.id,
            railSpans: railSpans.flatMap { [$0.start.timeIntervalSinceReferenceDate, $0.end.timeIntervalSinceReferenceDate] }
        )
        return pawprintLedgerMemo.value(for: key) {
            MapHomePawprintLedger.entries(readings: readings, railSpans: railSpans)
        }
    }

    /// 한 화면에서 여러 번 읽힌다. 입력(예상·확인 경로, 장부, 컷오프)이 같으면 이전 값을 쓴다(PRF1101A01).
    var pawprintWaypoints: [PawprintWaypoint] {
        let probe = MapHomePlaybackProbe.begin("pawprintWaypoints"); defer { MapHomePlaybackProbe.end(probe) }
        let ledger = pawprintLedger()
        let plan = MapHomeUnconfirmedPaws.plan(
            predicted: predictedMapRoutes, confirmed: confirmedPredictedRoutes,
            decidedTravelIDs: Set(model.snapshot.settings.predictedRouteDecisions.compactMap(\.route.travelID)),
            travel: currentDayDataSnapshot?.travel ?? [])
        let gapReadings = routeReadingsLoadState.isLoaded(for: model.selectedDate) ? historicalPlaybackReadings : []
        let cutoff = routeOverlayCutoff
        let calendarForDay = Calendar.autoupdatingCurrent
        let dayEnd = calendarForDay.date(byAdding: .day, value: 1, to: calendarForDay.startOfDay(for: model.selectedDate))
            ?? .distantFuture
        let ledgerCutoff = playbackDriver != nil ? dayEnd : cutoff
        let key = MapHomePawprintWaypointsKey(
            day: model.selectedDate, cutoff: cutoff, ledgerCutoff: ledgerCutoff,
            ledgerCount: ledger.count, ledgerFirst: ledger.first?.timestamp, ledgerLast: ledger.last?.timestamp,
            plan: plan, gapReadingsCount: gapReadings.count, gapReadingsLastID: gapReadings.last?.id
        )
        return pawprintWaypointsMemo.value(for: key) {
            makePawprintWaypoints(plan: plan, gapReadings: gapReadings, ledger: ledger,
                                  cutoff: cutoff, ledgerCutoff: ledgerCutoff)
        }
    }

    func makePawprintWaypoints(
        plan: MapHomeUnconfirmedPaws.Plan, gapReadings: [SensorReading], ledger: [MapHomePawprintLedger.Entry],
        cutoff routeOverlayCutoff: Date, ledgerCutoff: Date
    ) -> [PawprintWaypoint] {
        let hardCap = MapHomePawprintInteractionPolicy.markerLimit
        let predictedSegments = plan.predicted.map { route in
            (route: route, points: MapHomeGPSGapPredictionPolicy.predictedRailCoordinates(
                along: coordinates(for: route, through: routeOverlayCutoff)))
        }
        let confirmedSegments = plan.confirmed.map { route in
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
        for gap in MapHomeUnconfirmedPaws.subwayGapPoints(travel: plan.gapTravel, readings: gapReadings, through: routeOverlayCutoff, limit: hardCap - result.count) {
            result.append(PawprintWaypoint(index: result.count, coordinate: gap.coordinate, angle: gap.angle, isPredicted: true, timestamp: nil,
                predictedRoute: plan.gapRoutes[gap.travelID], speedMetersPerSecond: gap.speed))
        }
        return result
    }

    func applyAutoLandStyle(near: Bool) {
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

    func vectorPoint(
        in viewport: MapHomeVectorViewport?,
        for id: String
    ) -> CGPoint? {
        viewport?.markerPoints[id]
    }

    func rewardRecentCompletedDay(_ day: Date, asOf now: Date = .now) {
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
    func openDailyCardFromAlarm(fireDate: Date) {
        let calendar = Calendar.autoupdatingCurrent
        let hour = calendar.component(.hour, from: fireDate)
        let day = calendar.startOfDay(for: fireDate)
        let target = hour < 12 ? (calendar.date(byAdding: .day, value: -1, to: day) ?? day) : day
        model.selectedDate = target
        isDailyCardPresented = true
    }

    /// 알람 확인 시트에 넘길 항목(알람을 누르면 채워지고, 닫으면 비워진다).
    var alarmConfirmBinding: Binding<AlarmConfirmItem?> {
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
    var salaryTaskID: String {
        let parts: [String] = [
            "\(salaryAnnualPay)", "\(allowanceIsSelected)", "\(salaryMonthlyPay)", "\(salaryIsNetInput)", "\(salaryShowsNet)",
            "\(salaryMonthAccum)", "\(salaryPayHistoryRaw)", "\(scenePhase == .active)",
            "\(model.selectedDate.timeIntervalSince1970)", "\(model.snapshot.actuals.count)", "\(model.snapshot.places.count)",
        ]
        return parts.joined(separator: "|")
    }

    /// 선택한 날의 달력 항목 값(항목 id → 값). 공유 카드의 항목 고르기와 카드 값에 쓴다.
    var dailyMetricValues: [String: Double] {
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
    var isDayObservedToEnd: Bool {
        let calendar = Calendar.autoupdatingCurrent
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: model.selectedDate)) ?? .now
        return Date.now >= dayEnd
    }

    /// 하루 카드 데이터: 선택한 날짜의 대분류·걸음·이동·번 돈.
    var dailyCardData: MapHomeDailyCardData {
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
                isDayObservedToEnd ? "관측 \(MapHomeAlarmPolicy.hoursText(total))" : "관측 \(MapHomeAlarmPolicy.hoursText(total)) · 나머지는 미확인",
                isDayObservedToEnd ? "Observed \(MapHomeAlarmPolicy.hoursText(total))" : "Observed \(MapHomeAlarmPolicy.hoursText(total)) · rest unconfirmed"
            ),
            accessoryID: homeGrowthHistory.season.equippedAccessory,
            memoText: dayMemoCounts.total > 0
                ? language.text("메모 \(dayMemoCounts.total)개 · 지도 \(dayMemoCounts.map)개", "Memos \(dayMemoCounts.total) · map \(dayMemoCounts.map)")
                : nil,
            routePoints: daySummaryRoutePoints,
            homeLevel: MapHomeGrowthPolicy.level(on: model.selectedDate, in: homeGrowthHistory, calendar: MapHomeGrowthPolicy.localCalendar)
        )
    }

    /// 하루 카드 한 장. 지도가 보는 날은 읽어 둔 값을, 다른 날은 그날 기록을 따로 읽어 만든다(지도 날짜는 그대로 둔다).
    func dailyCardContent(for day: Date) async -> MapHomeDailyCardContent {
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
            homeLevel: MapHomeGrowthPolicy.level(on: day, in: homeGrowthHistory, calendar: MapHomeGrowthPolicy.localCalendar),
            memos: model.snapshot.memos,
            language: language,
            entries: { daySummaryEntries(from: $0) }
        )
    }

    var dayStepCount: Int? {
        // 지나간 날은 확정 요약의 걸음 수를 쓴다(센서 원본을 다시 읽지 않는다).
        if let sealed = model.sealedDay(for: model.selectedDate), sealed.stepCount > 0 { return sealed.stepCount }
        return MapHomeCounterTimelinePolicy.stepCount(readings: currentDayReadings, cutoff: nil)
    }

    /// 겹치는 구간을 병합해 총 소요 시간을 반환한다(같은 초 중복 계산 방지).
    static func unionDuration(_ spans: [TimeSpan]) -> TimeInterval {
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

    /// 저장된 안개 세기. 알 수 없는 값이면 옅게로 돌아간다.
    var fogStrength: MapHomeFogStrength {
        MapHomeFogStrength(rawValue: fogStrengthRaw) ?? .light
    }

    /// 하단 탭·떠 있는 독. 1급 항목은 일곱 개이고 **맨 왼쪽이 메뉴**다.
    ///
    /// 메뉴는 2026-10-26까지 왼쪽 위 원형 단추였다. 지도와 날짜 줄을 가리고,
    /// 손이 닿지 않는 구석이라 아래로 내렸다(대표 요청). 항목은 늘리지 않았다.
    var bottomActionBar: some View {
        HStack(spacing: 0) {
            bottomBarButton("line.3.horizontal", language.text("메뉴", "Menu")) {
                if isMenuOpen { isMenuOpen = false } else { openMenu() }
            }
            MapHomeBottomBarButton(title: language.text("달력", "Calendar"), action: { MapHomeInteractionMonitor.shared.begin("popup_calendar", duration: 1.2); isCalendarPresented.toggle() }) {
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

    func bottomBarButton(
        _ icon: String,
        _ title: String,
        action: @escaping () -> Void
    ) -> some View {
        MapHomeBottomBarButton(title: title, action: action) {
            TaptionBarIcon(systemImage: icon)
        }
    }

    var dateBadge: some View {
        let info = MapHomeDateBadgeInfo.resolve(date: model.selectedDate, localeIdentifier: language.locale.identifier)
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
        .taptionRaised(.rounded(isPlain ? 18 : 22), gloss: false)
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

    /// 메모나 계획이 있는 날(하루의 시작 시각). 날짜 줄에 점으로 보여 준다.
    var dataDayStarts: Set<Date> {
        let calendar = Calendar.autoupdatingCurrent
        var days = Set(model.snapshot.memos.map {
            calendar.startOfDay(for: $0.isTimeless == true ? $0.createdAt : $0.occurredAt)
        })
        days.formUnion(model.snapshot.plans.map { calendar.startOfDay(for: $0.span.start) })
        return days
    }

    /// 오늘이 아니면 한 번 눌러 오늘로 돌아가고, 오늘이면 옆으로 날짜 줄을 펼친다.
    func handleDateBadgeTap() {
        if !Calendar.autoupdatingCurrent.isDateInToday(model.selectedDate) {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { jumpToTodayAndFitRoutes() }
            return
        }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { isDateWeekExpanded.toggle() }
    }

    var header: some View {
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

    func headerDateButton(_ icon: String, amount: Int) -> some View {
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

    func headerIconAssetName(for systemImage: String) -> String? {
        switch systemImage {
        case "chevron.backward.2": "MapHomeNavigatePreviousDouble"
        case "chevron.left": "MapHomeNavigatePrevious"
        case "chevron.right": "MapHomeNavigateNext"
        case "chevron.forward.2": "MapHomeNavigateNextDouble"
        default: nil
        }
    }

    /// 오늘 근무 시간(지금·1분 전)과, 필요하면 이번 달·지난달 합계를 다시 세어 연봉 카운터 값을 만든다.
    func refreshSalary(includeMonth: Bool) async {
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
    func persistSalaryForLockScreen() {
        SalaryLiveSnapshot.write(salaryLive.map { live in
            SalaryLiveSnapshot(
                text: MapHomeSalaryPolicy.wonText(MapHomeSalaryPolicy.earnings(
                    workSeconds: live.todayWorkSeconds, hourlyRate: live.hourlyRate)),
                baseSeconds: live.todayWorkSeconds, hourlyRate: live.hourlyRate,
                measuredAt: live.measuredAt, isWorking: live.isWorking, tickSeconds: salaryTickSeconds
            )
        })
    }

    func salaryAnchor(viewport: MapHomeVectorViewport?, stickmanPoint: CGPoint?) -> CGPoint? {
        if let stickmanPoint {
            return CGPoint(x: stickmanPoint.x, y: stickmanPoint.y + MapHomeStickmanAnnotationLayout.centerOffset.y - 42)
        }
        guard let home = model.settings.frequentPlaces.first(where: { $0.kind == .home }),
              let pin = vectorPoint(in: viewport, for: vectorPlaceMarkerID(home.id)) else { return nil }
        // 화랑이가 집에 있으면 핀 안의 화랑이 바로 위, 아니면 집 지붕 위 날씨 배지 위에 둔다.
        return CGPoint(x: pin.x, y: pin.y + MapHomePlacePinLayout.salaryOffsetFromPinCenter)
    }

    func dayFallbackTotals(month: Date) async -> [Date: [String: TimeInterval]] {
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

    var appVersionFooter: some View {
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

    var dataProtectionStatusText: String {
        if model.securityStatus.settings.lockOnLaunch {
            return language.text("앱 열 때마다 잠금", "Locks whenever the app opens")
        }
        return model.securityStatus.hasPIN
            ? language.text("비밀번호 등록됨", "Password registered")
            : language.text("보호 설정 안 됨", "Not configured")
    }

    var sensorCollectionPermissionGate: RequiredPermissionGate {
        model.requiredPermissionGate(liveActivitiesEnabled: false)
    }

    var sensorPermissionCard: some View {
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

    func sensorPermissionIcon(_ permission: RequiredPermission) -> String {
        switch permission {
        case .locationAlways, .locationPrecise:
            "location.fill"
        case .motion:
            "figure.walk.motion"
        case .healthKitRequestCompleted, .calendar, .notifications, .liveActivities:
            "checkmark"
        }
    }

    func sensorPermissionTitle(_ permission: RequiredPermission) -> String {
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

    func sensorPermissionActionTitle(_ permission: RequiredPermission) -> String {
        switch permission {
        case .locationPrecise:
            language.text("설정 열기", "Open Settings")
        default:
            language.text("허용하기", "Allow")
        }
    }

    var sensorCollectionStatusText: String {
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

    var currentCoordinate: CLLocationCoordinate2D? {
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
    var lastKnownCoordinate: CLLocationCoordinate2D? {
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

    var hasConfirmedCurrentGPS: Bool {
        MapHomeCurrentGPSPolicy.isConfirmed(
            in: currentMapLocationReading.map { [$0] } ?? []
        )
    }

    func currentActivity(at minute: Int) -> MapHomeTimeSidebarActivity {
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

    var currentDayDataSnapshot: PlanDayDataSnapshot? {
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

    var isDayDataLoading: Bool {
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
    var currentDayReadings: [SensorReading] {
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

    /// 센서 기록 묶음의 변경 표지. 개수·마지막 번호만 봐서 값 비교가 O(1)이다.
    func readingsSignature(sourceRevision: UInt64?) -> MapHomeReadingsSignature {
        MapHomeReadingsSignature(
            day: Calendar.autoupdatingCurrent.startOfDay(for: model.selectedDate),
            sourceRevision: sourceRevision,
            storedCount: routeReadings.count, storedLastID: routeReadings.last?.id,
            liveCount: model.liveRouteState.readings.count, liveLastID: model.liveRouteState.readings.last?.id,
            latestID: model.latestSensorReading?.id
        )
    }

    var selectedPawprintPoint: GeoPoint? {
        guard !isDayPlaybackRunning,
              let coordinate = selectedPawprintCoordinate,
              let selection = MapHomePawprintInteractionPolicy.selection(
                timestamp: selectedPawprintTimestamp, isPredicted: false,
                selectedDate: model.selectedDate
              ), selection.minute == selectedTimelineMinute else { return nil }
        return wbsGeoPoint(coordinate)
    }

    func cachedCoordinate(
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

    var dateTitle: String {
        MapHomeDateText.string(
            from: model.selectedDate,
            format: selectedScope == .day
                ? language.dateTitleFormat
                : language.monthTitleFormat,
            locale: language.locale
        )
    }

    var dateTitleLabel: Text {
        let weekday = Calendar.autoupdatingCurrent.component(.weekday, from: model.selectedDate)
        let weekdayName = MapHomeDateText.string(
            from: model.selectedDate, format: language.weekdayFormat, locale: language.locale)
        let weekdayText = Text(" \(weekdayName)")
            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(17)), weight: .semibold))
            .foregroundStyle(dateColor(weekday: weekday))
        return datePartTitleLabel + weekdayText
    }

    var datePartTitleLabel: Text {
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

    var ink: Color {
        .tpInk
    }

    func dateColor(weekday: Int) -> Color {
        if weekday == 7 { return .tpSaturday }
        if TimelineAxisGrid.koreanHolidayName(on: model.selectedDate) != nil || weekday == 1 {
            return .tpHoliday
        }
        return ink
    }

    func moveDate(by amount: Int) {
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
}
