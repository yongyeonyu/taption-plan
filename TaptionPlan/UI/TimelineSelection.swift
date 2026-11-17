import SwiftUI
import UIKit
import MapKit

func weatherSymbolColor(
    _ weather: WeatherContext,
    component: WeatherSymbolPaletteComponent
) -> Color {
    let palette = WeatherSymbolKind(symbolName: weather.symbolName).palette
    let color = component == .primary ? palette.primary : palette.secondary
    return Color(red: color.red, green: color.green, blue: color.blue)
}

func weatherTimelineSpan(_ context: WeatherContext) -> TimeSpan {
    WeatherTimelineEngine.span(for: context)
}

func automaticSpanThroughNow(
    _ span: TimeSpan,
    asOf now: Date = .now
) -> TimeSpan? {
    guard span.start <= now else { return nil }
    return TimeSpan(start: span.start, end: min(span.end, now))
}

func weatherTimelineTitle(_ context: WeatherContext) -> String {
    let air = context.airQuality.map {
        " · 미세 " + $0.overallGrade.displayName
    } ?? ""
    return "\(AppRegion.current.temperature(celsius: context.temperatureCelsius))"
        + "° · " + context.condition + air
}

func weatherTimelineDetail(_ context: WeatherContext) -> String {
    var values = [
        "자동 날씨",
        context.observedAt.formatted(date: .omitted, time: .shortened),
    ]
    if let air = context.airQuality {
        values.append(
            "PM10 "
                + Int(air.pm10MicrogramsPerCubicMeter.rounded()).formatted()
                + " · PM2.5 "
                + Int(air.pm25MicrogramsPerCubicMeter.rounded()).formatted()
        )
    }
    return values.joined(separator: " · ")
}

struct TimelineSelection: Equatable {
    let title: String
    let span: TimeSpan
    let planID: UUID?
    let actualID: UUID?
    let travelID: UUID?
    let recordNodeID: String?
    let isRoute: Bool
    let categoryID: String?
    let categoryName: String?

    init(
        title: String,
        span: TimeSpan,
        planID: UUID?,
        actualID: UUID? = nil,
        travelID: UUID? = nil,
        recordNodeID: String? = nil,
        isRoute: Bool,
        categoryID: String? = nil,
        categoryName: String? = nil
    ) {
        self.title = title
        self.span = span
        self.planID = planID
        self.actualID = actualID
        self.travelID = travelID
        self.recordNodeID = recordNodeID
        self.isRoute = isRoute
        self.categoryID = categoryID
        self.categoryName = categoryName
    }
}

func isMovementActual(_ actual: ActualRecord) -> Bool {
    // 앱 이름은 임의의 낱말이라 제목만 보고 이동으로 오인하면 안 된다.
    if actual.categoryID == "appUsage" { return false }
    if actual.categoryID == "movement" { return true }
    if watchBehavior(actual)?.isMovement == true { return true }
    let title = actual.title.lowercased()
    return [
        "걷기", "걷", "달리기", "달리", "자전거", "차량", "자동차",
        "버스", "지하철", "택시", "기차", "비행기", "배", "이동",
    ].contains { title.contains($0) }
}

func isConfirmedMovementActual(_ actual: ActualRecord) -> Bool {
    if actual.behavior == "unconfirmed-gap" { return false }
    if actual.categoryID == ReviewCoverageEngine.unconfirmedCategoryID { return false }
    if actual.source == .manual { return isMovementActual(actual) }
    return isMovementActual(actual) && actual.confidence != .low
}

func movementActualTitle(_ actual: ActualRecord) -> String {
    MovementPresentation.title(for: actual)
}

func watchBehavior(_ actual: ActualRecord) -> WatchBehaviorKind? {
    actual.behavior.flatMap(WatchBehaviorKind.init(rawValue:))
}

func movementActualSymbol(_ actual: ActualRecord) -> String {
    MovementPresentation.symbol(for: actual)
}

func restActualTitle(_ actual: ActualRecord) -> String {
    switch watchBehavior(actual) {
    case .stationary: "휴식 1"
    case .sitting: "휴식 2"
    case .standing: "휴식 3"
    case .lying: "휴식 4"
    default:
        actual.title.localizedCaseInsensitiveContains("휴식")
            || actual.title.localizedCaseInsensitiveContains("정지")
            ? "휴식 1"
            : actual.title
    }
}

func timelineWeatherSelection(
    _ context: WeatherContext
) -> TimelineSelection {
    TimelineSelection(
        title: weatherTimelineTitle(context),
        span: weatherTimelineSpan(context),
        planID: nil,
        recordNodeID: "automatic.weather.\(context.id.uuidString)",
        isRoute: false,
        categoryID: "weather",
        categoryName: "날씨"
    )
}

func timelineWeather(
    at date: Date,
    in contexts: [WeatherContext]
) -> WeatherContext? {
    contexts
        .filter { weatherTimelineSpan($0).contains(date) }
        .min {
            abs($0.observedAt.timeIntervalSince(date))
                < abs($1.observedAt.timeIntervalSince(date))
        }
}

extension TimelineSelection {
    /// Memo identity follows the concrete timeline record, not its category.
    /// This prevents two sleep/activity/location blocks on the same day from
    /// sharing the same note storage.
    var memoTargetID: String? {
        if let recordNodeID, recordNodeID.hasPrefix("automatic.") {
            return recordNodeID
        }
        if let actualID {
            return "automatic.actual.\(actualID.uuidString)"
        }
        if let travelID {
            return "automatic.travel.\(travelID.uuidString)"
        }
        if let planID {
            return "plan.\(planID.uuidString)"
        }
        return recordNodeID
    }

    var preferredDetailSection: TimelineDetailSection {
        switch categoryID {
        case "location":
            return .location
        case "movement":
            return .movement
        case "sleep":
            return .sleep
        case "activity":
            return .activity
        case ReviewCoverageEngine.unconfirmedCategoryID:
            return .activity
        case "weather":
            return .weather
        case "exercise", "workout":
            return .activity
        case "photo":
            return .photo
        case TimelineRowKind.memo.rawValue:
            return .memo
        case "event":
            return .event
        case "schedule", "calendar":
            return .schedule
        default:
            return isRoute ? .map : .action
        }
    }
}

extension TimelineSelection {
    static func photo(_ cluster: PhotoCluster) -> TimelineSelection {
        TimelineSelection(
            title: "사진",
            span: cluster.detailSpan,
            planID: nil,
            recordNodeID: "automatic.photo.\(cluster.id)",
            isRoute: false,
            categoryID: "photo",
            categoryName: "사진"
        )
    }
}

extension PhotoCluster {
    var detailSpan: TimeSpan {
        // PhotoClusterer keeps each cluster chronological. Avoid allocating
        // and sorting a second date array every time the detail panel asks
        // for the selected photo span.
        let start = photos.first?.capturedAt ?? capturedAt
        let end = photos.last?.capturedAt ?? capturedAt
        return TimeSpan(
            start: start,
            end: max(start.addingTimeInterval(60), end)
        )
    }
}

func playheadFocusSpan(around date: Date) -> TimeSpan {
    // Relationship links are a supporting detail view, not the 20 Hz
    // playhead renderer. Quantize the graph's center to five-minute buckets so
    // scrubbing within a bucket reuses the same graph instead of rebuilding
    // all automatic/routine/action nodes on every delivered tick.
    let bucket = 5 * 60.0
    let bucketStart = floor(
        date.timeIntervalSinceReferenceDate / bucket
    ) * bucket
    let center = Date(timeIntervalSinceReferenceDate: bucketStart)
    return TimeSpan(
        start: center.addingTimeInterval(-15 * 60),
        end: center.addingTimeInterval(15 * 60)
    )
}
