import SwiftUI

/// 편집기 안팎에서 함께 쓰는 클립 만들기·표기 도우미.
///
/// 화면 본문과 떼어 두는 이유는 `MapHomeNLEClipEditor.swift`의 줄 예산이다.
/// 여기 있는 값은 하루 구간에서 클립을 세우는 순수 계산이라 화면 상태를 읽지 않는다.
extension MapHomeNLEClipEditor {
    // MARK: - 만들기

    /// 하루 구간을 클립으로 만든다.
    ///
    /// 클립의 원본 구간은 자기 기록뿐 아니라 옆의 빈 시간까지 품는다. 그래야
    /// 동영상 편집기처럼 클립을 빈 자리로 끌어 옮기거나 늘릴 수 있다. 빈 시간에는
    /// 원본 기록이 없으므로 지어내는 데이터도 없다.
    ///
    /// `dayOffset`은 기준일에서 뺀 날 수다(어제 = −1). 구간은 0…1,440에 묶여 있으므로
    /// 클립을 세울 때 그만큼 옮기고, 트랙 범위도 그 날로 둔다(NLE1029A02).
    static func makeMainTrack(segments: [MapHomeTimeRailSegment], dayOffset: Int = 0) -> NLETrack {
        let shift = dayOffset * NLETrack.dayMinutes
        let dayEnd = shift + NLETrack.dayMinutes
        let ordered = segments
            .filter { $0.endMinute > $0.startMinute }
            .sorted { $0.startMinute < $1.startMinute }
        var spans: [(segment: MapHomeTimeRailSegment, start: Int, end: Int)] = []
        var cursor = 0
        for segment in ordered {
            let start = max(segment.startMinute, cursor)
            let end = min(segment.endMinute, NLETrack.dayMinutes)
            guard start < end else { continue }
            spans.append((segment, start + shift, end + shift))
            cursor = end
        }
        guard !spans.isEmpty else {
            return NLETrack(clips: [], rangeStartMinute: shift, rangeEndMinute: dayEnd)
        }

        // 원본 구간을 하루 전체로 늘려 잇는다. 가운데 빈 시간은 앞 구간이,
        // 맨 앞·맨 뒤 빈 시간은 그 구간이 품는다.
        var parents: [Range<Int>] = spans.map { $0.start..<$0.end }
        for index in parents.indices {
            if index > 0 {
                parents[index - 1] = parents[index - 1].lowerBound..<parents[index].lowerBound
            }
        }
        parents[0] = shift..<parents[0].upperBound
        parents[parents.count - 1] = parents[parents.count - 1].lowerBound..<dayEnd

        let clips = spans.enumerated().compactMap { index, span -> NLEClip? in
            let option = option(
                forCategoryID: span.segment.categoryID,
                title: span.segment.title,
                behavior: span.segment.behavior
            )
            let region = parents[index]
            let parent = NLEClipParent(
                startMinute: region.lowerBound,
                endMinute: region.upperBound,
                sourceIDs: span.segment.sourceIDs,
                option: option,
                fillOption: ActivitySectionOverrideEngine.unconfirmedOption
            )
            return NLEClip(
                id: "main|\(clipIDPrefix(dayOffset))\(span.segment.id)",
                option: option,
                startMinute: span.start,
                endMinute: span.end,
                parent: parent,
                origin: NLEClipOrigin(
                    startMinute: span.start,
                    endMinute: span.end,
                    option: option
                )
            )
        }
        return NLETrack(clips: clips, rangeStartMinute: shift, rangeEndMinute: dayEnd)
    }

    /// 지난 날의 클립 ID 앞머리. 기준일은 예전 ID를 그대로 쓴다.
    private static func clipIDPrefix(_ dayOffset: Int) -> String {
        dayOffset == 0 ? "" : "d\(dayOffset)|"
    }

    /// 상세활동 기록을 하루 전체에 걸쳐 세운다.
    ///
    /// 각 기록의 울타리는 자기가 속한 원본 구간이다. 그래서 상세활동을 그 구간
    /// 안에서 옮기거나 자를 수는 있어도, 다른 구간으로 넘어가지는 않는다.
    static func makeSubTrack(
        details: [MapHomeSectionDetail],
        segments: [MapHomeTimeRailSegment],
        dayOffset: Int = 0
    ) -> NLETrack {
        let shift = dayOffset * NLETrack.dayMinutes
        let ordered = segments
            .filter { $0.endMinute > $0.startMinute }
            .sorted { $0.startMinute < $1.startMinute }
        let clips = details.compactMap { detail -> NLEClip? in
            guard detail.endMinute > detail.startMinute else { return nil }
            let owner = ordered.first {
                detail.startMinute >= $0.startMinute && detail.endMinute <= $0.endMinute
            } ?? ordered.first {
                detail.startMinute < $0.endMinute && detail.endMinute > $0.startMinute
            }
            let detailOption = option(
                forCategoryID: detail.categoryID,
                title: detail.title,
                behavior: detail.behavior
            )
            let fill = owner.map {
                option(forCategoryID: $0.categoryID, title: $0.title, behavior: $0.behavior)
            } ?? ActivitySectionOverrideEngine.unconfirmedOption
            let parent = NLEClipParent(
                startMinute: (owner?.startMinute ?? detail.startMinute) + shift,
                endMinute: (owner?.endMinute ?? detail.endMinute) + shift,
                sourceIDs: [detail.id],
                option: detailOption,
                fillOption: fill
            )
            return NLEClip(
                id: "sub|\(clipIDPrefix(dayOffset))\(detail.id.uuidString)",
                option: detailOption,
                startMinute: detail.startMinute + shift,
                endMinute: detail.endMinute + shift,
                parent: parent,
                origin: NLEClipOrigin(
                    startMinute: detail.startMinute + shift,
                    endMinute: detail.endMinute + shift,
                    option: detailOption
                )
            )
        }
        return NLETrack(
            clips: clips,
            rangeStartMinute: shift,
            rangeEndMinute: shift + NLETrack.dayMinutes,
            fillsGaps: false
        )
    }

    static func option(
        forCategoryID categoryID: String,
        title: String,
        behavior: String?
    ) -> ActivityCorrectionOption {
        ActivityCorrectionOption(
            id: "clip.\(categoryID).\(behavior ?? "none")",
            title: title,
            behavior: behavior,
            categoryID: categoryID,
            systemImage: MapHomeSidebarMajorCategory.all
                .first { $0.id == categoryID }?
                .systemImage ?? "circle.fill",
            isAutomatic: false,
            isCustom: false
        )
    }

    static func option(
        for category: MapHomeSidebarMajorCategory,
        language: MapHomeLanguage
    ) -> ActivityCorrectionOption {
        if category.id.hasPrefix("custom:") {
            return ActivityCorrectionOption.custom(category.title)
        }
        return ActivityCorrectionOption(
            id: "phase.\(category.id)",
            title: category.localizedTitle(language),
            behavior: category.id == "unconfirmed" ? "unconfirmed-gap" : nil,
            categoryID: category.id,
            systemImage: category.systemImage,
            isAutomatic: false,
            isCustom: false
        )
    }

    /// 「센서 원본」 열을 그날의 원본 표본·HealthKit 수면으로 세운다.
    func loadSensorEvidence() async -> (segments: [MapHomeNLESensorSegment], readings: [SensorReading]) {
        let day = await model.planDayDataSnapshot(for: date, forceReload: false)
        let segments = MapHomeNLESensorEvidence.channelSegments(
            readings: day.readings, sleepSessions: model.sleepSessions,
            healthActuals: day.actuals, dayStart: Calendar.autoupdatingCurrent.startOfDay(for: date)
        )
        return (segments, day.readings)
    }

    static func tint(for categoryID: String) -> Color {
        Color(hex: MapHomePastelPalette.hex(categoryID))
    }

    /// 시각 글자. 지난 날의 음수 분도 24시간으로 감는다(−30 → "23:30"). 기준일 끝만 "24:00"이다.
    static func minuteLabel(_ minute: Int) -> String {
        if minute == NLETrack.dayMinutes { return "24:00" }
        let wrapped = NLEDayWindow.minuteOfDay(minute)
        return String(format: "%02d:%02d", wrapped / 60, wrapped % 60)
    }

    static func rangeLabel(_ start: Int, _ end: Int) -> String {
        "\(minuteLabel(start))–\(minuteLabel(end))"
    }

    static func durationLabel(_ minutes: Int, language: MapHomeLanguage) -> String {
        let hours = minutes / 60
        let remainder = minutes % 60
        if language == .english {
            if hours > 0, remainder > 0 { return "\(hours)h \(remainder)m" }
            if hours > 0 { return "\(hours)h" }
            return "\(remainder)m"
        }
        if hours > 0, remainder > 0 { return "\(hours)시간 \(remainder)분" }
        if hours > 0 { return "\(hours)시간" }
        return "\(remainder)분"
    }

    static func hourLabel(_ hour: Int) -> String {
        String(format: "%02d", NLEDayWindow.wrappedHour(hour * 60))
    }
}

/// 센서 원본 열 안의 한 줄(UIX1031A17). 얻을 수 있는 정보를 종류별로 나눠 세운다.
enum MapHomeNLESensorChannel: Int, CaseIterable, Sendable {
    case motion
    case health
    case screen
    case network
    case place

    var systemImage: String {
        switch self {
        case .motion: "figure.walk"
        case .health: "heart.fill"
        case .screen: "iphone"
        case .network: "wifi"
        case .place: "mappin.and.ellipse"
        }
    }

    func title(_ language: MapHomeLanguage) -> String {
        switch self {
        case .motion: language.text("움직임", "Motion")
        case .health: language.text("헬스·워치", "Health·Watch")
        case .screen: language.text("화면·전원", "Screen·Power")
        case .network: language.text("연결", "Connections")
        case .place: language.text("장소 단서", "Place hints")
        }
    }

    /// 움직임·헬스 줄은 대분류와 견줘 되돌릴 수 있다. 나머지는 읽기만 한다.
    var isRestorable: Bool { self == .motion || self == .health }
}

struct MapHomeNLESensorSegment: Identifiable, Equatable, Sendable {
    let channel: MapHomeNLESensorChannel
    let startMinute: Int
    let endMinute: Int
    let title: String
    let categoryID: String
    let behavior: String?

    var id: String { "\(channel.rawValue):\(startMinute)-\(endMinute)" }
}

/// 클립 편집기의 「센서 원본」 열(CAT1029A02).
///
/// 대분류를 다시 그리지 않고, 실제 원본만으로 분 단위 라벨을 세운다.
/// 우선순위는 HealthKit 수면 > HealthKit 기록(운동 등) > iPhone 모션·GPS 속도다.
/// 원본이 없는 시간은 비워 두고, 라벨마다 출처를 붙인다.
enum MapHomeNLESensorEvidence {
    /// 표본 하나가 다음 표본 없이도 이어진다고 보는 최대 시간(분).
    static let maximumHoldMinutes = 10
    /// 이보다 짧은 조각은 앞 조각에 붙인다(센서 흔들림).
    static let minimumRunMinutes = 3
    /// GPS 속도가 이 이상이면 걷기가 아닌 차량 이동으로 본다(약 22km/h).
    static let vehicleSpeedMetersPerSecond = 6.0

    private struct Label: Equatable {
        let title: String
        let categoryID: String
        let behavior: String?
    }

    static func segments(
        readings: [SensorReading],
        sleepSessions: [SleepSession],
        healthActuals: [ActualRecord],
        dayStart: Date,
        now: Date = .now
    ) -> [MapHomeTimeRailSegment] {
        var slots = [Label?](repeating: nil, count: NLETrack.dayMinutes)
        let ordered = readings.sorted { $0.timestamp < $1.timestamp }
        for (index, reading) in ordered.enumerated() {
            guard let label = label(for: reading) else { continue }
            let start = minute(reading.timestamp, dayStart)
            let next = index + 1 < ordered.count ? minute(ordered[index + 1].timestamp, dayStart) : start + 1
            fill(&slots, start, min(max(next, start + 1), start + maximumHoldMinutes), label)
        }
        for actual in healthActuals where actual.source == .healthKit && !AutomaticRecordTimelineEngine.isSleep(actual) {
            let label = Label(title: "\(actual.title) · HealthKit", categoryID: actual.categoryID, behavior: actual.behavior)
            fill(&slots, minute(actual.startedAt, dayStart), minute(actual.endedAt ?? now, dayStart), label)
        }
        for session in sleepSessions where session.asleepDuration > 0 {
            let label = Label(title: "수면 · HealthKit", categoryID: "sleep", behavior: WatchBehaviorKind.sleep.rawValue)
            fill(&slots, minute(session.span.start, dayStart), minute(min(session.span.end, now), dayStart), label)
        }
        return runs(slots)
    }

    private static func label(for reading: SensorReading) -> Label? {
        if reading.gpsAvailable, let speed = reading.speedMetersPerSecond,
           speed >= vehicleSpeedMetersPerSecond, reading.motion != .walking, reading.motion != .running {
            return Label(title: "차량 · GPS 속도", categoryID: "movement", behavior: MotionKind.automotive.rawValue)
        }
        switch reading.motion {
        case .stationary: return Label(title: "정지 · iPhone", categoryID: "activity", behavior: MotionKind.stationary.rawValue)
        case .walking: return Label(title: "걷기 · iPhone", categoryID: "movement", behavior: MotionKind.walking.rawValue)
        case .running: return Label(title: "달리기 · iPhone", categoryID: "exercise", behavior: MotionKind.running.rawValue)
        case .cycling: return Label(title: "자전거 · iPhone", categoryID: "movement", behavior: MotionKind.cycling.rawValue)
        case .automotive: return Label(title: "차량 · iPhone", categoryID: "movement", behavior: MotionKind.automotive.rawValue)
        case .unknown: return nil
        }
    }

    private static func minute(_ date: Date, _ dayStart: Date) -> Int {
        min(max(Int((date.timeIntervalSince(dayStart) / 60).rounded()), 0), NLETrack.dayMinutes)
    }

    private static func fill(_ slots: inout [Label?], _ start: Int, _ end: Int, _ label: Label) {
        let lower = max(0, start), upper = min(NLETrack.dayMinutes, end)
        guard lower < upper else { return }
        for index in lower..<upper { slots[index] = label }
    }

    private static func mergedRuns(_ slots: [Label?]) -> [(start: Int, end: Int, label: Label?)] {
        var runs: [(start: Int, end: Int, label: Label?)] = []
        for (index, label) in slots.enumerated() {
            if let last = runs.last, last.label == label, last.end == index {
                runs[runs.count - 1].end = index + 1
            } else {
                runs.append((index, index + 1, label))
            }
        }
        var merged: [(start: Int, end: Int, label: Label?)] = []
        for run in runs {
            if let last = merged.last, last.end == run.start,
               run.end - run.start < minimumRunMinutes || last.label == run.label {
                merged[merged.count - 1].end = run.end
            } else {
                merged.append(run)
            }
        }
        return merged
    }

    private static func runs(_ slots: [Label?]) -> [MapHomeTimeRailSegment] {
        mergedRuns(slots).compactMap { run in
            guard let label = run.label else { return nil }
            return MapHomeTimeRailSegment(
                startMinute: run.start, endMinute: run.end, categoryID: label.categoryID,
                title: label.title, behavior: label.behavior
            )
        }
    }

    private static func channelRuns(_ slots: [Label?], channel: MapHomeNLESensorChannel) -> [MapHomeNLESensorSegment] {
        mergedRuns(slots).compactMap { run in
            guard let label = run.label else { return nil }
            return MapHomeNLESensorSegment(
                channel: channel, startMinute: run.start, endMinute: run.end,
                title: label.title, categoryID: label.categoryID, behavior: label.behavior
            )
        }
    }

    // MARK: 센서 원본 다섯 줄(UIX1031A17)

    /// 센서 원본 열을 다섯 줄로 나눠 얻을 수 있는 정보를 모두 세운다.
    /// 움직임(iPhone 모션·GPS 속도) · 헬스(HealthKit 수면·운동, 워치 운동·행동) · 화면·전원 · 연결(Wi-Fi·차량 오디오) · 장소(역·노선·공항·항만·물 위·위치 품질).
    /// 한 분에 값이 둘 이상이면 줄마다 따로 서므로 서로 가리지 않는다. 값이 없는 시간은 비워 둔다.
    static func channelSegments(
        readings: [SensorReading],
        sleepSessions: [SleepSession],
        healthActuals: [ActualRecord],
        dayStart: Date,
        now: Date = .now
    ) -> [MapHomeNLESensorSegment] {
        let ordered = readings.sorted { $0.timestamp < $1.timestamp }
        var motion = [Label?](repeating: nil, count: NLETrack.dayMinutes)
        var health = [Label?](repeating: nil, count: NLETrack.dayMinutes)
        var screen = [Label?](repeating: nil, count: NLETrack.dayMinutes)
        var network = [Label?](repeating: nil, count: NLETrack.dayMinutes)
        var place = [Label?](repeating: nil, count: NLETrack.dayMinutes)
        for (index, reading) in ordered.enumerated() {
            let start = minute(reading.timestamp, dayStart)
            let next = index + 1 < ordered.count ? minute(ordered[index + 1].timestamp, dayStart) : start + 1
            let end = min(max(next, start + 1), start + maximumHoldMinutes)
            if let label = label(for: reading) { fill(&motion, start, end, label) }
            if let label = healthLabel(for: reading) { fill(&health, start, end, label) }
            if let label = screenLabel(for: reading) { fill(&screen, start, end, label) }
            if let label = networkLabel(for: reading) { fill(&network, start, end, label) }
            if let label = placeLabel(for: reading) { fill(&place, start, end, label) }
        }
        for actual in healthActuals where actual.source == .healthKit && !AutomaticRecordTimelineEngine.isSleep(actual) {
            let label = Label(title: "\(actual.title) · HealthKit", categoryID: actual.categoryID, behavior: actual.behavior)
            fill(&health, minute(actual.startedAt, dayStart), minute(actual.endedAt ?? now, dayStart), label)
        }
        for session in sleepSessions where session.asleepDuration > 0 {
            let label = Label(title: "수면 · HealthKit", categoryID: "sleep", behavior: WatchBehaviorKind.sleep.rawValue)
            fill(&health, minute(session.span.start, dayStart), minute(min(session.span.end, now), dayStart), label)
        }
        return channelRuns(motion, channel: .motion)
            + channelRuns(health, channel: .health)
            + channelRuns(screen, channel: .screen)
            + channelRuns(network, channel: .network)
            + channelRuns(place, channel: .place)
    }

    /// 워치가 알려 준 운동 종류나 세밀한 행동. 분류가 있는 행동은 대분류로 되돌릴 수 있다.
    private static func healthLabel(for reading: SensorReading) -> Label? {
        if let kind = reading.watchWorkoutKind, !kind.isEmpty {
            return Label(title: "운동 \(kind) · 워치", categoryID: "exercise", behavior: kind)
        }
        if let behavior = reading.behavior, !behavior.isEmpty,
           let kind = WatchBehaviorKind(rawValue: behavior) {
            return Label(title: "\(behavior) · 워치", categoryID: kind == .sleep ? "sleep" : "activity", behavior: behavior)
        }
        return nil
    }

    private static func screenLabel(for reading: SensorReading) -> Label? {
        if reading.powerState?.isCharging == true, reading.screenIsOn != true {
            return Label(title: "충전 중 · 화면 꺼짐", categoryID: Self.deviceCategoryID, behavior: "charging-screen-off")
        }
        if reading.powerState?.isCharging == true {
            return Label(title: "충전 중 · 화면 켜짐", categoryID: Self.deviceCategoryID, behavior: "charging-screen-on")
        }
        switch reading.screenIsOn {
        case .some(true): return Label(title: "화면 켜짐", categoryID: Self.deviceCategoryID, behavior: "screen-on")
        case .some(false): return Label(title: "화면 꺼짐", categoryID: Self.deviceCategoryID, behavior: "screen-off")
        case .none: return nil
        }
    }

    private static func networkLabel(for reading: SensorReading) -> Label? {
        if let route = reading.carAudioRouteName, !route.isEmpty {
            return Label(title: "차량 오디오 · \(route)", categoryID: Self.networkCategoryID, behavior: "car-audio")
        }
        if let ssid = reading.connectedWiFiSSID, !ssid.isEmpty {
            return Label(title: "Wi-Fi · \(ssid)", categoryID: Self.networkCategoryID, behavior: "wifi")
        }
        return nil
    }

    private static func placeLabel(for reading: SensorReading) -> Label? {
        if reading.nearAirport { return Label(title: "공항 근처", categoryID: Self.placeCategoryID, behavior: "airport") }
        if reading.nearPort { return Label(title: "항만 근처", categoryID: Self.placeCategoryID, behavior: "port") }
        if reading.onWater { return Label(title: "물 위", categoryID: Self.placeCategoryID, behavior: "water") }
        if reading.matchesRailRoute {
            return Label(title: "철도 노선 위", categoryID: Self.placeCategoryID, behavior: "rail")
        }
        if reading.matchesPublicTransitRoute {
            return Label(title: "대중교통 노선 위", categoryID: Self.placeCategoryID, behavior: "transit")
        }
        if let station = reading.nearbyStationName, !station.isEmpty {
            return Label(title: "정류장 근처 · \(station)", categoryID: Self.placeCategoryID, behavior: "station")
        }
        if reading.nearbyStation { return Label(title: "역 근처", categoryID: Self.placeCategoryID, behavior: "station") }
        if !reading.gpsAvailable { return Label(title: "GPS 없음", categoryID: Self.placeCategoryID, behavior: "no-gps") }
        if reading.locationFixQuality == .approximate {
            return Label(title: "대략 위치", categoryID: Self.placeCategoryID, behavior: "approximate")
        }
        return nil
    }

    static let deviceCategoryID = "sensor.device"
    static let networkCategoryID = "sensor.network"
    static let placeCategoryID = "sensor.place"

    /// 고른 분에 가장 가까운 측정값(앞뒤 `maximumHoldMinutes` 안).
    static func nearestReading(atMinute minute: Int, in readings: [SensorReading], dayStart: Date) -> SensorReading? {
        let target = dayStart.addingTimeInterval(Double(minute) * 60)
        let best = readings.min { abs($0.timestamp.timeIntervalSince(target)) < abs($1.timestamp.timeIntervalSince(target)) }
        guard let best, abs(best.timestamp.timeIntervalSince(target)) <= Double(maximumHoldMinutes) * 60 else { return nil }
        return best
    }

    /// 측정값 하나에 들어 있는 값을 읽기 쉬운 줄로 풀어 쓴다. 값이 없는 항목은 적지 않는다.
    static func rawLines(for reading: SensorReading, language: MapHomeLanguage) -> [String] {
        func t(_ ko: String, _ en: String) -> String { language.text(ko, en) }
        var lines: [String] = []
        lines.append(t("측정 ", "At ") + reading.timestamp.formatted(date: .omitted, time: .standard)
            + (reading.sourceDevice.map { " · " + $0.rawValue } ?? ""))
        lines.append(t("모션 ", "Motion ") + reading.motion.rawValue + " (" + reading.motionConfidence.rawValue + ")")
        if let steps = reading.stepCount { lines.append(t("걸음 ", "Steps ") + steps.formatted()) }
        if let meters = reading.walkingRunningDistanceMeters {
            lines.append(t("걷고 뛴 거리 ", "Walk/run distance ") + MapHomeDayTravelSummary.distanceText(meters))
        }
        if let pace = reading.currentPaceSecondsPerMeter, pace > 0, pace.isFinite {
            let perKm = Int((pace * 1_000).rounded())
            lines.append(t("현재 페이스 ", "Pace ") + "\(perKm / 60)'\(String(format: "%02d", perKm % 60))\"/km")
        }
        if let cadence = reading.currentCadenceStepsPerSecond {
            lines.append(t("걸음 속도 ", "Cadence ") + String(format: "%.1f", cadence) + t("보/초", " steps/s"))
        }
        if let speed = reading.speedMetersPerSecond, speed >= 0 {
            var text = String(format: "%.1f km/h", speed * 3.6)
            if let accuracy = reading.speedAccuracyMetersPerSecond, accuracy >= 0 {
                text += String(format: " ±%.1f", accuracy * 3.6)
            }
            lines.append(t("GPS 속도 ", "GPS speed ") + text)
        }
        if let course = reading.courseDegrees, course >= 0 {
            lines.append(t("진행 방향 ", "Course ") + String(format: "%.0f°", course))
        }
        if let accuracy = reading.point?.horizontalAccuracy {
            lines.append(t("위치 정확도 ", "Location accuracy ") + String(format: "%.0f m", accuracy)
                + (reading.locationFixQuality.map { " (" + $0.rawValue + ")" } ?? ""))
        }
        lines.append(t("GPS ", "GPS ") + (reading.gpsAvailable ? t("사용 가능", "available") : t("없음", "unavailable")))
        if let altitude = reading.relativeAltitudeMeters {
            lines.append(t("상대 고도 ", "Relative altitude ") + String(format: "%.1f m", altitude))
        }
        if let pressure = reading.pressureKilopascals {
            lines.append(t("기압 ", "Pressure ") + String(format: "%.2f kPa", pressure))
        }
        if reading.floorsAscended != nil || reading.floorsDescended != nil {
            lines.append(t("층 오름/내림 ", "Floors up/down ") + "\(reading.floorsAscended ?? 0)/\(reading.floorsDescended ?? 0)")
        }
        if let floor = reading.systemFloor { lines.append(t("건물 층 ", "Building floor ") + "\(floor)") }
        if let on = reading.screenIsOn {
            var text = on ? t("켜짐", "on") : t("꺼짐", "off")
            if let brightness = reading.screenBrightness { text += String(format: " (%.0f%%)", brightness * 100) }
            lines.append(t("화면 ", "Screen ") + text)
        }
        if let power = reading.powerState, power != .unknown { lines.append(t("전원 ", "Power ") + power.rawValue) }
        if let ssid = reading.connectedWiFiSSID, !ssid.isEmpty { lines.append("Wi-Fi " + ssid) }
        if let streak = reading.subwayWiFiObservationStreak, streak > 0 {
            lines.append(t("지하철 Wi-Fi 연속 ", "Subway Wi-Fi streak ") + "\(streak)")
        }
        if let route = reading.carAudioRouteName, !route.isEmpty { lines.append(t("차량 오디오 ", "Car audio ") + route) }
        if let station = reading.nearbyStationName, !station.isEmpty {
            lines.append(t("가까운 정류장 ", "Nearest stop ") + station)
        } else if reading.nearbyStation {
            lines.append(t("역 근처", "Near a station"))
        }
        var flags: [String] = []
        if reading.matchesRailRoute { flags.append(t("철도 노선", "rail route")) }
        if reading.matchesPublicTransitRoute { flags.append(t("대중교통 노선", "transit route")) }
        if reading.frequentStops { flags.append(t("잦은 정차", "frequent stops")) }
        if reading.rideHailingHint { flags.append(t("호출 택시 단서", "ride-hail hint")) }
        if reading.nearAirport { flags.append(t("공항", "airport")) }
        if reading.nearPort { flags.append(t("항만", "port")) }
        if reading.onWater { flags.append(t("물 위", "on water")) }
        if !flags.isEmpty { lines.append(t("위치 단서 ", "Place hints ") + flags.joined(separator: ", ")) }
        if let workout = reading.watchWorkoutKind, !workout.isEmpty { lines.append(t("워치 운동 ", "Watch workout ") + workout) }
        if let behavior = reading.behavior, !behavior.isEmpty {
            var text = behavior
            if let score = reading.behaviorConfidenceScore { text += String(format: " (%.0f%%)", score * 100) }
            lines.append(t("워치 행동 ", "Watch behavior ") + text)
            if let evidence = reading.behaviorEvidence, !evidence.isEmpty {
                lines.append(t("행동 근거 ", "Evidence ") + evidence.joined(separator: ", "))
            }
        }
        if let g = reading.watchAccelerationStandardDeviationG {
            lines.append(t("워치 가속도 변동 ", "Watch accel. spread ") + String(format: "%.3f g", g))
        }
        if let summary = reading.deviceMotionSummary {
            lines.append(t("기기 모션 ", "Device motion ") + String(format: "%.3f g", summary.meanUserAccelerationG)
                + " · " + "\(summary.sampleCount)" + t("표본", " samples"))
        }
        return lines
    }
}
