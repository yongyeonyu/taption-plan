import Foundation
import TaptionPlanCore

/// 오늘 요약 값을 ActivityKit용 값으로 바꾼다. 계산 자체는 지도 카운터와 같은 정책을 쓴다.
enum LiveActivityDaySummaryBuilder {
    static let categoryLimit = 4
    /// 값이 분 단위라 1분에 한 번만 다시 센다. 센서 저장마다 하루 전체를 다시 세지 않는다.
    static let refreshSeconds: TimeInterval = 60

    static func make(
        categorySeconds: [String: TimeInterval],
        steps: Int?,
        meters: Double,
        categoryColors: [String: String],
        language: MapHomeLanguage,
        distanceText: (Double) -> String = { MapHomeDayTravelSummary.distanceText($0) }
    ) -> SensorCollectionDaySummary {
        let safeMeters = meters.isFinite ? max(0, meters) : 0
        let categories = categorySeconds
            .filter { $0.key != "unconfirmed" && $0.value >= 60 }
            .sorted { ($1.value, $0.key) < ($0.value, $1.key) }
            .prefix(categoryLimit)
            .map { id, seconds in
                let presentation = MapHomeSidebarMajorCategory.presentation(
                    for: id,
                    categoryColors: categoryColors
                )
                return SensorCollectionDaySummary.Category(
                    id: id,
                    title: presentation.localizedTitle(language),
                    minutes: Int(seconds / 60),
                    durationText: DurationText.localized(seconds, english: language == .english),
                    hex: presentation.hex
                )
            }
        return SensorCollectionDaySummary(
            categories: Array(categories),
            steps: max(0, steps ?? 0),
            meters: Int(safeMeters.rounded()),
            distanceText: distanceText(safeMeters)
        )
    }
}

/// 마지막으로 만든 요약. 같은 날·같은 언어면 1분 동안 다시 계산하지 않는다.
@MainActor
final class LiveActivityDaySummaryCache {
    static let shared = LiveActivityDaySummaryCache()

    private var day: Date?
    private var language: MapHomeLanguage?
    private var computedAt: Date?
    private var value: SensorCollectionDaySummary?

    /// 같은 날에 읽기를 건너뛰었을 때 돌려줄 이전 값.
    func lastValue(day: Date, language: MapHomeLanguage) -> SensorCollectionDaySummary? {
        self.day == day && self.language == language ? value : nil
    }

    func reusable(day: Date, language: MapHomeLanguage, now: Date) -> SensorCollectionDaySummary? {
        guard let computedAt, now >= computedAt,
              now.timeIntervalSince(computedAt) < LiveActivityDaySummaryBuilder.refreshSeconds else { return nil }
        return lastValue(day: day, language: language)
    }

    func store(_ value: SensorCollectionDaySummary, day: Date, language: MapHomeLanguage, now: Date) {
        self.day = day
        self.language = language
        computedAt = now
        self.value = value
    }
}

extension AppModel {
    /// 다이나믹 아일랜드용 오늘 요약. 잠금(외부 화면 가림) 중에는 보내지 않는다.
    func liveActivityDaySummary(
        now: Date = .now,
        calendar: Calendar = .autoupdatingCurrent,
        cache: LiveActivityDaySummaryCache = .shared
    ) async -> SensorCollectionDaySummary? {
        guard !TaptionExternalPrivacyStore.isLocked else { return nil }
        let day = calendar.startOfDay(for: now)
        let language = MapHomeLanguage.current
        if let cached = cache.reusable(day: day, language: language, now: now) { return cached }

        let data = await planDayDataSnapshot(for: day, forceReload: false)
        // 읽기가 거절돼 빈 값이 온 경우 0으로 덮지 않는다.
        if data.sourceRevision == 0, data.actuals.isEmpty, data.travel.isEmpty, data.readings.isEmpty {
            return cache.lastValue(day: day, language: language)
        }
        let span = MapHomeCounterTimelinePolicy.daySpan(of: day)
        let readings = MapHomeRouteReadingsPolicy.merging(
            existing: data.readings,
            loaded: liveRouteState.readings + (latestSensorReading.map { [$0] } ?? []),
            in: span
        )
        let seconds = TaptionSealedDayBuilder.categoryDurations(
            actuals: data.actuals,
            travel: data.travel,
            stays: data.places,
            placeKinds: FrequentPlaceResolutionEngine().kindsByPlaceKey(settings.frequentPlaces),
            day: span,
            asOf: now
        )
        let summary = LiveActivityDaySummaryBuilder.make(
            categorySeconds: seconds,
            steps: MapHomeCounterTimelinePolicy.stepCount(readings: readings, cutoff: nil),
            meters: MapHomeCounterTimelinePolicy.travelMeters(segments: data.travel, cutoff: nil, day: span),
            categoryColors: settings.mapCategoryColors,
            language: language
        )
        cache.store(summary, day: day, language: language, now: now)
        return summary
    }
}
