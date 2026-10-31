import Foundation
import TaptionPlanCore

struct WatchSensorTimelineData: Sendable {
    let summaries: [TaptionWatchSensorSummary]
    let accelerationChunks: [TaptionWatchAccelerationChunk]

    var accelerationSamples: [TaptionWatchAccelerationSample] {
        let samples = accelerationChunks.flatMap(\.samples)
        return Dictionary(
            samples.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        ).values.sorted {
            if $0.capturedAt == $1.capturedAt {
                return $0.sequence < $1.sequence
            }
            return $0.capturedAt < $1.capturedAt
        }
    }
}

enum ActivityClassificationRecordOrdering {
    static func sorted(
        _ records: [ActualRecord],
        cancellationCheck: () throws -> Void
    ) throws -> [ActualRecord] {
        try RouteTimelineCancellableSort.sorted(
            records,
            by: {
                if $0.startedAt != $1.startedAt {
                    return $0.startedAt < $1.startedAt
                }
                return $0.id.uuidString < $1.id.uuidString
            },
            cancellationCheck: cancellationCheck
        )
    }
}

struct WatchSummaryVersion: Codable, Comparable, Sendable {
    let sequence: Int
    let revision: Int

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.sequence == rhs.sequence
            ? lhs.revision < rhs.revision
            : lhs.sequence < rhs.sequence
    }
}

struct ActivityClassificationSourceSnapshot: Sendable {
    let revision: UInt64
    let actuals: [ActualRecord]
    let travel: [TravelSegment]
    let corrections: [UUID: ActivityCorrection]
    let suppressedIDs: Set<UUID>

    init(revision: UInt64, snapshot: TaptionDataSnapshot) {
        self.revision = revision
        actuals = snapshot.actuals
        travel = snapshot.travel
        corrections = snapshot.settings.activityCorrections
        suppressedIDs = snapshot.settings.suppressedActualIDs
    }
}

final class ActivityClassificationRevisionFence: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64

    init(_ revision: UInt64 = 0) {
        value = revision
    }

    var currentRevision: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(to revision: UInt64) {
        lock.lock()
        value = revision
        lock.unlock()
    }

    func check(_ expectedRevision: UInt64) throws {
        guard currentRevision == expectedRevision else { throw CancellationError() }
    }
}

@MainActor
enum ActivityClassificationRetry {
    static func apply<Result: Sendable>(
        capture: @MainActor () -> ActivityClassificationSourceSnapshot,
        currentRevision: @MainActor () -> UInt64,
        classify: @MainActor (ActivityClassificationSourceSnapshot) async -> Result?,
        commit: @MainActor (ActivityClassificationSourceSnapshot, Result) -> Void
    ) async -> Bool {
        for _ in 0..<2 {
            guard !Task.isCancelled else { return false }
            let source = capture()
            let result = await classify(source)
            guard !Task.isCancelled else { return false }
            guard source.revision == currentRevision() else { continue }
            guard let result else { return false }
            commit(source, result)
            return true
        }
        return false
    }
}

enum TaptionWatchDaySummaryFactory {
    static func make(
        plans: [PlanRecord],
        actuals: [ActualRecord],
        at date: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> TaptionWatchDaySummary {
        let dayStart = calendar.startOfDay(for: date)
        let dayEnd = calendar.date(
            byAdding: .day,
            value: 1,
            to: dayStart
        ) ?? dayStart.addingTimeInterval(86_400)
        let day = TimeSpan(start: dayStart, end: dayEnd)
        let scheduled = plans.filter {
            $0.status != .skipped && $0.span.intersection(with: day) != nil
        }
        let recordedSpans: [TimeSpan] = actuals.compactMap {
            $0.span(asOf: date).intersection(with: day)
        }
        let activeCategoryIDs: Set<String> = [
            "movement",
            "exercise",
            "health",
        ]
        let activeSpans: [TimeSpan] = actuals.compactMap { actual -> TimeSpan? in
            guard activeCategoryIDs.contains(actual.categoryID) else {
                return nil
            }
            return actual.span(asOf: date).intersection(with: day)
        }
        return TaptionWatchDaySummary(
            date: dayStart,
            scheduledCount: scheduled.count,
            completedCount: scheduled.filter {
                $0.status == .completed
            }.count,
            recordedMinutes: minutes(in: recordedSpans),
            activeMinutes: minutes(in: activeSpans)
        )
    }

    private static func minutes(in spans: [TimeSpan]) -> Int {
        let ordered = spans.sorted { $0.start < $1.start }
        guard var current = ordered.first else { return 0 }
        var duration: TimeInterval = 0
        for span in ordered.dropFirst() {
            if span.start <= current.end {
                current.end = max(current.end, span.end)
            } else {
                duration += current.duration
                current = span
            }
        }
        duration += current.duration
        return max(0, Int((duration / 60).rounded()))
    }
}

/// Error messages the app also matches on or tests by their leading sentence,
/// so the Korean and English wording live side by side.
enum AppModelMessage: Equatable, Sendable {
    case dataLoadFailed(String)
    case locationReadFailed(String)
    case sensorSaveFailed(String)
    case floorOutOfRange(lower: Int, upper: Int)

    func lead(preference: AppLanguagePreference = .current) -> String {
        switch self {
        case .dataLoadFailed:
            AppLanguagePreference.text(
                korean: "저장된 데이터를 불러오지 못했습니다.",
                english: "Saved data could not be loaded.",
                preference: preference
            )
        case .locationReadFailed:
            AppLanguagePreference.text(
                korean: "위치 기록을 읽지 못했습니다.",
                english: "Could not read location records.",
                preference: preference
            )
        case .sensorSaveFailed:
            AppLanguagePreference.text(
                korean: "센서 기록을 저장하지 못했습니다.",
                english: "Could not save sensor records.",
                preference: preference
            )
        case let .floorOutOfRange(lower, upper):
            AppLanguagePreference.text(
                korean: "층수는 \(FloorLabel.korean(lower))부터 \(FloorLabel.korean(upper)) 사이로 입력해 주세요.",
                english: "Enter a floor between \(FloorLabel.english(lower)) and \(FloorLabel.english(upper)).",
                preference: preference
            )
        }
    }

    func text(preference: AppLanguagePreference = .current) -> String {
        switch self {
        case let .dataLoadFailed(detail),
             let .locationReadFailed(detail),
             let .sensorSaveFailed(detail):
            "\(lead(preference: preference)) \(detail)"
        case .floorOutOfRange:
            lead(preference: preference)
        }
    }

    /// True for a load-failure message in either language, so recovery still
    /// clears it after the app language changed.
    static func isDataLoadFailure(_ message: String?) -> Bool {
        guard let message else { return false }
        return [AppLanguagePreference.korean, .english].contains {
            message.hasPrefix(dataLoadFailed("").lead(preference: $0))
        }
    }
}

extension PermissionState {
    var isGranted: Bool {
        self == .authorized || self == .limited
    }

    var settingsLabel: String {
        switch self {
        case .notDetermined:
            AppLanguagePreference.text(korean: "연결하기", english: "Connect")
        case .denied:
            AppLanguagePreference.text(korean: "권한 필요", english: "Permission needed")
        case .limited:
            AppLanguagePreference.text(korean: "일부 허용", english: "Partially allowed")
        case .authorized:
            AppLanguagePreference.text(korean: "연결됨", english: "Connected")
        case .unavailable:
            AppLanguagePreference.text(korean: "사용 불가", english: "Unavailable")
        }
    }
}

extension CatCoat {
    init(catStyle: CatStyle) {
        switch catStyle {
        case .white: self = .white
        case .calico: self = .calico
        case .mackerel: self = .mackerel
        case .black: self = .black
        case .gray: self = .gray
        case .cheese: self = .cheese
        case .cow: self = .cow
        }
    }

    var catStyle: CatStyle {
        switch self {
        case .white: .white
        case .calico: .calico
        case .mackerel: .mackerel
        case .black: .black
        case .gray: .gray
        case .cheese: .cheese
        case .cow: .cow
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
