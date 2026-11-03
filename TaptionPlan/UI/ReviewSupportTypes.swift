import Charts
import SwiftUI

/// 화면 본문에서 계산하면 스크롤·제스처마다 기간 전체를 다시 훑게 된다.
/// 데이터·배율·기준일이 바뀔 때 한 번만 만들어 두고 그대로 그린다.
struct ReviewContent: Equatable {
    /// 배율이 정한 기간 전체. 막대의 가로 범위와 옆으로 넘기기가 이 값을 쓴다.
    var period: TimeSpan
    /// 합계·눈금판·목록이 함께 읽는 단 하나의 구간 묶음. 고른 칸이 없으면
    /// `[period]` 하나뿐이라 지금까지의 화면과 똑같다.
    var spans: [TimeSpan]
    /// 손가락으로 켜고 끌 수 있는 칸. 하루 배율에서는 비어 있다.
    var pickableBuckets: [ReviewPeriodBucket]
    var selectedBucketCount: Int
    var plannedCategories: [CategoryDuration]
    var contexts: [ReviewContext]
    var groups: [RecordCategoryGroup]
    /// 링과 목록에 실제로 그린 파생 기록. 탭 대상도 같은 배열에서 찾는다.
    var displayActuals: [ActualRecord]
    /// 하루 기록 목록은 일과를 먼저 보여 주고 그 안에 활동을 넣는다.
    var phaseGroups: [RecordCategoryGroup]
    var rings: [RecordClockRing]
    /// 가장 바깥의 일과 고리. 하루 배율에서만 만들어진다.
    var phaseRing: RecordClockDetailRing?
    /// 수면 단계와 이동수단은 별도 상세 고리 없이 활동 띠 위에 그린다.
    var activityRings: [RecordClockDetailRing]
    /// 날씨·위치는 상세 고리와 분리해 환경 정보로 표시한다.
    var contextRings: [RecordClockDetailRing]
    /// 일별 일과를 합산한 값. 주·월·년 막대와 범례가 이 값만 읽는다.
    var phaseDurations: [CategoryDuration]
    var chartBuckets: [RecordChartBucket]
    /// 고른 구간에 걸친 막대. 비어 있으면 모두 고른 것과 같다.
    var selectedChartBucketIDs: Set<String>

    static let empty = ReviewContent(
        period: TimeSpan(start: .now, end: .now),
        spans: [],
        pickableBuckets: [],
        selectedBucketCount: 0,
        plannedCategories: [],
        contexts: [],
        groups: [],
        displayActuals: [],
        phaseGroups: [],
        rings: [],
        phaseRing: nil,
        activityRings: [],
        contextRings: [],
        phaseDurations: [],
        chartBuckets: [],
        selectedChartBucketIDs: []
    )
}

/// 눈금판을 깨우는 간격. 재생 중에는 화면 갱신 예산인 60Hz까지만 올리고,
/// 멈춰 있을 때는 현재 시각 바늘이 흐르도록 분마다 한 번만 깨운다.
struct RecordClockSchedule: TimelineSchedule {
    var isPlaying: Bool

    func entries(
        from startDate: Date,
        mode: TimelineScheduleMode
    ) -> AnyIterator<Date> {
        let step = isPlaying ? RecordClockEngine.frameInterval : 60
        var next = startDate
        return AnyIterator {
            defer { next = next.addingTimeInterval(step) }
            return next
        }
    }
}

struct ReviewContentKey: Equatable {
    let revision: UInt64
    let scale: TimeScale
    let date: Date
    let selectedBucketIDs: Set<String>
    let selectedChartBucketID: String?
    let healthRefreshedAt: Date?
}

struct ReviewDetailSelection: Equatable {
    var kind: RecordClockDetailKind
    var token: String
}

enum ReviewClockHighlight: Equatable {
    case phase(arcID: String, token: String)
    case category(String)
    case detail(ReviewDetailSelection)
}

struct PlaybackContextReadout {
    var weatherToken: String?
    var locationToken: String?

    var isEmpty: Bool {
        weatherToken == nil && locationToken == nil
    }
}

struct LinearClockItem {
    var title: String
    var tint: Color
}

enum CircularActivityLabelQuadrant: CaseIterable, Hashable {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight

    init(clockFraction: Double) {
        guard clockFraction.isFinite else {
            self = .topRight
            return
        }
        let fraction = clockFraction - floor(clockFraction)
        switch fraction {
        case 0..<0.25:
            self = .topRight
        case 0.25..<0.5:
            self = .bottomRight
        case 0.5..<0.75:
            self = .bottomLeft
        default:
            self = .topLeft
        }
    }

    var isLeft: Bool {
        self == .topLeft || self == .bottomLeft
    }

    var isTop: Bool {
        self == .topLeft || self == .topRight
    }
}

enum CircularActivityLabelPaging {
    static func clampedIndex(_ index: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(index, 0), count - 1)
    }

    static func index(
        movingBy offset: Int,
        from index: Int,
        count: Int
    ) -> Int {
        clampedIndex(index + offset, count: count)
    }
}

enum CircularClockTapBand: Equatable {
    case phase
    case activity

    static func resolve(
        distance: Double,
        outerRadius: Double,
        phaseBandWidth: Double,
        bandGap: Double,
        activityBandWidth: Double,
        tolerance: Double = 8
    ) -> CircularClockTapBand? {
        let phaseRadius = outerRadius - phaseBandWidth / 2
        let activityRadius = outerRadius
            - phaseBandWidth
            - bandGap
            - activityBandWidth / 2
        let phaseDelta = abs(distance - phaseRadius)
        let activityDelta = abs(distance - activityRadius)
        let hitsPhase = phaseDelta <= phaseBandWidth / 2 + tolerance
        let hitsActivity = activityDelta <= activityBandWidth / 2 + tolerance

        switch (hitsPhase, hitsActivity) {
        case (true, true):
            return activityDelta <= phaseDelta ? .activity : .phase
        case (true, false):
            return .phase
        case (false, true):
            return .activity
        case (false, false):
            return nil
        }
    }
}

struct CircularActivityLabel: Identifiable {
    let id: String
    let groupID: String
    let groupName: String
    let child: RecordGroupChild
    let start: Date
    let anchorFraction: Double
    let quadrant: CircularActivityLabelQuadrant
}

/// Scroll geometry can arrive faster than the SwiftUI layout budget. Keep the
/// latest offset outside view state and publish the playhead at most 60Hz.
final class LinearScrollTracker {
    var latestOffset: CGFloat = 0
    var lastPublishedUptime: TimeInterval = 0
}

final class CircularPlayheadTracker {
    var lastPublishedUptime: TimeInterval = 0
    var isDragging = false
}

struct ReviewUnconfirmedSelection: Identifiable {
    let id = UUID()
    let span: TimeSpan
}

struct ReviewQuickActivitySelection: Identifiable {
    let recordID: UUID
    let displayedSpan: TimeSpan

    var id: UUID {
        ActivityFragmentCorrectionEngine.stableID(
            sourceID: recordID,
            span: displayedSpan
        )
    }
}

struct ReviewRecordSelection {
    let record: ActualRecord
    let displayedSpan: TimeSpan
}

enum RecentActivitySelectionStore {
    private static let key = "review.recentActivityOptionIDs"
    private static let limit = 8

    static func ids() -> [String] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let ids = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    static func prioritize(
        _ options: [ActivityCorrectionOption]
    ) -> [ActivityCorrectionOption] {
        let recentIDs = ids()
        let rank = Dictionary(
            recentIDs.enumerated().map { ($1, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return options.enumerated()
            .sorted { left, right in
                let leftRank = rank[left.element.id]
                    ?? recentIDs.count + left.offset
                let rightRank = rank[right.element.id]
                    ?? recentIDs.count + right.offset
                return leftRank == rightRank
                    ? left.offset < right.offset
                    : leftRank < rightRank
            }
            .map(\.element)
    }

    static func remember(_ option: ActivityCorrectionOption) {
        var next = ids()
        next.removeAll { $0 == option.id }
        next.insert(option.id, at: 0)
        next = Array(next.prefix(limit))
        guard let data = try? JSONEncoder().encode(next) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
