import CoreLocation
import MapKit
import Observation
import OSLog
import SwiftUI
import UIKit
import TaptionPlanCore

struct MapHomeSectionEditSelection: Identifiable {
    let id = UUID()
    let date: Date
    let minute: Int
    let activity: MapHomeTimeSidebarActivity
    let segment: MapHomeTimeRailSegment
    let details: [MapHomeSectionDetail]
    /// 같은 날의 다른 구간. 편집 화면에서 흐리게 함께 보여 준다.
    var daySegments: [MapHomeTimeRailSegment] = []
    /// 하루 전체의 상세 활동. 선택한 구간 밖의 활동도 흐리게 보여 준다.
    var dayDetails: [MapHomeSectionDetail] = []

    /// 고른 구간의 실제 시각. 클립 편집기가 하루 전체를 다시 덮으므로,
    /// 저장 뒤 되돌아갈 자리를 이 값으로 계산한다.
    var selectedSpan: TimeSpan {
        let calendar = Calendar.autoupdatingCurrent
        let dayStart = calendar.startOfDay(for: date)
        func at(_ minute: Int) -> Date {
            calendar.date(byAdding: .minute, value: minute, to: dayStart)
                ?? dayStart
        }
        let start = at(segment.startMinute)
        return TimeSpan(start: start, end: max(start, at(segment.endMinute)))
    }
}

enum MapHomeSectionEditLayout {
    static let boundaryHandleHeight: CGFloat = 8

    static func handleCenterY(
        boundaryY: CGFloat,
        frameHeight: CGFloat
    ) -> CGFloat {
        let halfHeight = boundaryHandleHeight / 2
        return min(
            max(halfHeight, boundaryY + halfHeight),
            max(halfHeight, frameHeight - halfHeight)
        )
    }
}

struct MapHomeSectionViewportState: Hashable {
    var startMinute: Int
    var durationMinutes: Int

    var range: ClosedRange<Int> {
        startMinute...min(1_440, startMinute + durationMinutes)
    }
}

enum MapHomeSectionViewportMath {
    static let minimumDurationMinutes = 30
    static let maximumDurationMinutes = 1_440

    static func initialState(
        segmentStart: Int,
        segmentEnd: Int
    ) -> MapHomeSectionViewportState {
        // 편집 화면은 24시간 전체를 한 번에 보여 준다. 선택한 구간은 아래에서 강조한다.
        _ = (segmentStart, segmentEnd)
        return state(centerMinute: 720, durationMinutes: maximumDurationMinutes)
    }

    static func zoomed(
        from origin: MapHomeSectionViewportState,
        magnification: CGFloat,
        anchorY: CGFloat,
        height: CGFloat
    ) -> MapHomeSectionViewportState {
        guard magnification.isFinite, magnification > 0, height > 0 else {
            return origin
        }
        let duration = min(
            maximumDurationMinutes,
            max(
                minimumDurationMinutes,
                Int((CGFloat(origin.durationMinutes) / magnification).rounded())
            )
        )
        let fraction = min(max(anchorY / height, 0), 1)
        let anchorMinute = CGFloat(origin.startMinute)
            + CGFloat(origin.durationMinutes) * fraction
        let proposedStart = Int(
            (anchorMinute - CGFloat(duration) * fraction).rounded()
        )
        return MapHomeSectionViewportState(
            startMinute: min(max(proposedStart, 0), 1_440 - duration),
            durationMinutes: duration
        )
    }

    static func minute(
        atY y: CGFloat,
        height: CGFloat,
        viewport: MapHomeSectionViewportState
    ) -> Int {
        let fraction = min(max(y / max(height, 1), 0), 1)
        return min(
            viewport.range.upperBound,
            max(
                viewport.range.lowerBound,
                viewport.startMinute
                    + Int((fraction * CGFloat(viewport.durationMinutes)).rounded())
            )
        )
    }

    static func acceptsDetailSlice(
        translation: CGSize,
        minimumDistance: CGFloat = 64
    ) -> Bool {
        translation.width >= minimumDistance
            && abs(translation.width) > abs(translation.height) * 1.5
    }

    private static func state(
        centerMinute: Int,
        durationMinutes: Int
    ) -> MapHomeSectionViewportState {
        let duration = min(
            maximumDurationMinutes,
            max(minimumDurationMinutes, durationMinutes)
        )
        return MapHomeSectionViewportState(
            startMinute: min(
                max(centerMinute - duration / 2, 0),
                maximumDurationMinutes - duration
            ),
            durationMinutes: duration
        )
    }
}

enum MapHomeSectionTimelineLayoutMath {
    static let timeGutterWidth: CGFloat = 52
    static let minimumGap: CGFloat = 8
    static let trailingInset: CGFloat = 8
    static let detailColumnSpacing: CGFloat = 4

    struct DetailColumn: Hashable {
        let index: Int
        let count: Int

        static let single = DetailColumn(index: 0, count: 1)
    }

    private struct DetailInterval {
        let id: UUID
        let startMinute: Int
        let endMinute: Int
    }

    static func detailFrame(leftWidth: CGFloat) -> CGRect {
        let minX = timeGutterWidth + minimumGap
        return CGRect(
            x: minX,
            y: 0,
            width: max(1, leftWidth - minX - trailingInset),
            height: 1
        )
    }

    static func detailFrame(
        leftWidth: CGFloat,
        column: DetailColumn
    ) -> CGRect {
        let container = detailFrame(leftWidth: leftWidth)
        let count = max(1, column.count)
        let index = min(max(column.index, 0), count - 1)
        let totalSpacing = detailColumnSpacing * CGFloat(count - 1)
        let width = max(
            1,
            (container.width - totalSpacing) / CGFloat(count)
        )
        return CGRect(
            x: container.minX
                + CGFloat(index) * (width + detailColumnSpacing),
            y: container.minY,
            width: width,
            height: container.height
        )
    }

    static func detailColumns(
        for details: [MapHomeSectionDetail],
        visibleRange: ClosedRange<Int>
    ) -> [UUID: DetailColumn] {
        let intervals = details.compactMap { detail -> DetailInterval? in
            let start = max(detail.startMinute, visibleRange.lowerBound)
            let end = min(detail.endMinute, visibleRange.upperBound)
            guard start < end else { return nil }
            return DetailInterval(
                id: detail.id,
                startMinute: start,
                endMinute: end
            )
        }
        .sorted { lhs, rhs in
            if lhs.startMinute == rhs.startMinute {
                if lhs.endMinute == rhs.endMinute {
                    return lhs.id.uuidString < rhs.id.uuidString
                }
                return lhs.endMinute < rhs.endMinute
            }
            return lhs.startMinute < rhs.startMinute
        }

        var result: [UUID: DetailColumn] = [:]
        var group: [DetailInterval] = []
        var groupEnd = Int.min
        for interval in intervals {
            if !group.isEmpty, interval.startMinute >= groupEnd {
                assignColumns(in: group, to: &result)
                group.removeAll(keepingCapacity: true)
                groupEnd = Int.min
            }
            group.append(interval)
            groupEnd = max(groupEnd, interval.endMinute)
        }
        assignColumns(in: group, to: &result)
        return result
    }

    private static func assignColumns(
        in group: [DetailInterval],
        to result: inout [UUID: DetailColumn]
    ) {
        guard !group.isEmpty else { return }
        var columnEnds: [Int] = []
        var indices: [UUID: Int] = [:]
        for interval in group {
            let index = columnEnds.firstIndex {
                $0 <= interval.startMinute
            } ?? columnEnds.count
            if index == columnEnds.count {
                columnEnds.append(interval.endMinute)
            } else {
                columnEnds[index] = interval.endMinute
            }
            indices[interval.id] = index
        }
        let count = max(1, columnEnds.count)
        for interval in group {
            result[interval.id] = DetailColumn(
                index: indices[interval.id] ?? 0,
                count: count
            )
        }
    }
}

struct MapHomeSectionPreviewPiece: Identifiable {
    let id: String
    let startMinute: Int
    let endMinute: Int
    let category: MapHomeSidebarMajorCategory
}

enum MapHomeSectionBoundaryMath {
    static let minimumPublishInterval: TimeInterval = 1.0 / 60.0

    static func minute(
        baseMinute: Int,
        translation: CGFloat,
        trackHeight: CGFloat,
        visibleRange: ClosedRange<Int>,
        limit: Int,
        isStart: Bool
    ) -> Int {
        let duration = max(1, visibleRange.upperBound - visibleRange.lowerBound)
        let delta = Int(
            (translation / max(trackHeight, 1) * CGFloat(duration)).rounded()
        )
        let raw = baseMinute + delta
        return isStart
            ? min(max(raw, visibleRange.lowerBound), limit - 1)
            : max(min(raw, visibleRange.upperBound), limit + 1)
    }

    static func shouldPublish(
        lastUptime: TimeInterval,
        currentUptime: TimeInterval,
        isFinal: Bool
    ) -> Bool {
        isFinal || currentUptime - lastUptime >= minimumPublishInterval
    }
}
