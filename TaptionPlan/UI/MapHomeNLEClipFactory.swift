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
    static func makeMainTrack(segments: [MapHomeTimeRailSegment]) -> NLETrack {
        let ordered = segments
            .filter { $0.endMinute > $0.startMinute }
            .sorted { $0.startMinute < $1.startMinute }
        var spans: [(segment: MapHomeTimeRailSegment, start: Int, end: Int)] = []
        var cursor = 0
        for segment in ordered {
            let start = max(segment.startMinute, cursor)
            let end = min(segment.endMinute, NLETrack.dayMinutes)
            guard start < end else { continue }
            spans.append((segment, start, end))
            cursor = end
        }
        guard !spans.isEmpty else {
            return NLETrack(clips: [])
        }

        // 원본 구간을 하루 전체로 늘려 잇는다. 가운데 빈 시간은 앞 구간이,
        // 맨 앞·맨 뒤 빈 시간은 그 구간이 품는다.
        var parents: [Range<Int>] = spans.map { $0.start..<$0.end }
        for index in parents.indices {
            if index > 0 {
                parents[index - 1] = parents[index - 1].lowerBound..<parents[index].lowerBound
            }
        }
        parents[0] = 0..<parents[0].upperBound
        parents[parents.count - 1] = parents[parents.count - 1].lowerBound..<NLETrack.dayMinutes

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
                id: "main|\(span.segment.id)",
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
        return NLETrack(clips: clips)
    }

    /// 상세활동 기록을 하루 전체에 걸쳐 세운다.
    ///
    /// 각 기록의 울타리는 자기가 속한 원본 구간이다. 그래서 상세활동을 그 구간
    /// 안에서 옮기거나 자를 수는 있어도, 다른 구간으로 넘어가지는 않는다.
    static func makeSubTrack(
        details: [MapHomeSectionDetail],
        segments: [MapHomeTimeRailSegment]
    ) -> NLETrack {
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
                startMinute: owner?.startMinute ?? detail.startMinute,
                endMinute: owner?.endMinute ?? detail.endMinute,
                sourceIDs: [detail.id],
                option: detailOption,
                fillOption: fill
            )
            return NLEClip(
                id: "sub|\(detail.id.uuidString)",
                option: detailOption,
                startMinute: detail.startMinute,
                endMinute: detail.endMinute,
                parent: parent,
                origin: NLEClipOrigin(
                    startMinute: detail.startMinute,
                    endMinute: detail.endMinute,
                    option: detailOption
                )
            )
        }
        return NLETrack(clips: clips, fillsGaps: false)
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
    func loadSensorEvidence() async -> [MapHomeTimeRailSegment] {
        let day = await model.planDayDataSnapshot(for: date, forceReload: false)
        return MapHomeNLESensorEvidence.segments(
            readings: day.readings, sleepSessions: model.sleepSessions,
            healthActuals: day.actuals, dayStart: Calendar.autoupdatingCurrent.startOfDay(for: date)
        )
    }

    static func tint(for categoryID: String) -> Color {
        Color(hex: MapHomePastelPalette.hex(categoryID))
    }

    static func minuteLabel(_ minute: Int) -> String {
        let clamped = min(max(minute, 0), NLETrack.dayMinutes)
        return String(format: "%02d:%02d", clamped / 60, clamped % 60)
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
        String(format: "%02d", hour % 24)
    }
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

    private static func runs(_ slots: [Label?]) -> [MapHomeTimeRailSegment] {
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
        return merged.compactMap { run in
            guard let label = run.label else { return nil }
            return MapHomeTimeRailSegment(
                startMinute: run.start, endMinute: run.end, categoryID: label.categoryID,
                title: label.title, behavior: label.behavior
            )
        }
    }
}
