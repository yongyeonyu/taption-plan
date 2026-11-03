import SwiftUI
import UIKit
import MapKit

struct TimelineAxisMarker: Identifiable {
    let id: String
    let date: Date?
    let fraction: Double
    let label: String
    let isCurrent: Bool
    let holidayName: String?

    init(
        id: String,
        date: Date? = nil,
        fraction: Double,
        label: String,
        isCurrent: Bool,
        holidayName: String? = nil
    ) {
        self.id = id
        self.date = date
        self.fraction = fraction
        self.label = label
        self.isCurrent = isCurrent
        self.holidayName = holidayName
    }
}

struct TimelineRowModel: Identifiable {
    let id: String
    let title: String
    let category: PlanCategory?
    let categoryID: String?
    let dotColor: Color
    let iconName: String?
    let customFillColor: Color?
    let customActualColor: Color?
    let isSystemAutomatic: Bool
    let height: CGFloat
    let blocks: [TimelineBlock]
    let blockStarts: [Double]
    let prefixMaximumBlockEnds: [Double]

    init(
        title: String,
        id: String? = nil,
        category: PlanCategory? = nil,
        categoryID: String? = nil,
        dotColor: Color? = nil,
        systemImage: String? = nil,
        fillColor: Color? = nil,
        actualColor: Color? = nil,
        isSystemAutomatic: Bool = false,
        height: CGFloat = 60,
        blocks: [TimelineBlock]
    ) {
        self.id = id ?? categoryID ?? title
        self.title = title
        self.category = category
        self.categoryID = categoryID
        self.dotColor = dotColor ?? category?.darkColor ?? .clear
        self.iconName = systemImage
        self.customFillColor = fillColor
        self.customActualColor = actualColor
        self.isSystemAutomatic = isSystemAutomatic
        self.height = height
        let sortedBlocks = blocks.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.length != $1.length { return $0.length > $1.length }
            return $0.id.uuidString < $1.id.uuidString
        }
        self.blocks = sortedBlocks
        blockStarts = sortedBlocks.map { Double($0.start) }
        prefixMaximumBlockEnds =
            TimelineVisibleIntervalIndex.prefixMaximumEnds(
                starts: blockStarts,
                lengths: sortedBlocks.map { Double($0.length) }
            )
    }

    var fillColor: Color {
        customFillColor
            ?? category?.color
            ?? Color.tpControlFill
    }

    var actualColor: Color {
        customActualColor
            ?? category?.darkColor
            ?? Color.tpSecondary
    }
}

struct TimelineBlock: Identifiable {
    let id: UUID
    let planID: UUID?
    let title: String
    let isGoal: Bool
    let start: CGFloat
    let length: CGFloat
    let top: CGFloat
    let height: CGFloat
    let isFixed: Bool
    let groupCount: Int?
    let actualFraction: Double?
    let status: PlanStatus
    let isActual: Bool
    let opensLocationTimeline: Bool
    let minimumWidth: CGFloat
    let startsAt: Date?
    let endsAt: Date?
    let detailText: String?
    let categoryID: String?
    let categoryName: String?
    let actualID: UUID?
    let travelID: UUID?
    let recordNodeID: String?
    let fillColor: Color?
    let actualColor: Color?
    let styleKey: String
    /// 어플 줄 전용. 막대가 넓으면 이 토큰으로 실제 앱 이름을 그린다.
    let appUsageTokenData: Data?

    init(
        id: UUID = UUID(),
        planID: UUID? = nil,
        title: String,
        start: CGFloat,
        length: CGFloat,
        top: CGFloat = 16,
        height: CGFloat = 26,
        isFixed: Bool = false,
        groupCount: Int? = nil,
        actualFraction: Double? = nil,
        status: PlanStatus = .planned,
        isActual: Bool = false,
        opensLocationTimeline: Bool = false,
        minimumWidth: CGFloat = 18,
        startsAt: Date? = nil,
        endsAt: Date? = nil,
        detailText: String? = nil,
        categoryID: String? = nil,
        categoryName: String? = nil,
        isGoal: Bool = false,
        appUsageTokenData: Data? = nil,
        actualID: UUID? = nil,
        travelID: UUID? = nil,
        recordNodeID: String? = nil,
        fillColor: Color? = nil,
        actualColor: Color? = nil,
        styleKey: String? = nil
    ) {
        self.id = id
        self.planID = planID
        self.title = title
        self.isGoal = isGoal
        self.start = start
        self.length = length
        self.top = top
        self.height = height
        self.isFixed = isFixed
        self.groupCount = groupCount
        self.actualFraction = actualFraction
        self.status = status
        self.isActual = isActual
        self.opensLocationTimeline = opensLocationTimeline
        self.minimumWidth = minimumWidth
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.detailText = detailText
        self.categoryID = categoryID
        self.categoryName = categoryName
        self.appUsageTokenData = appUsageTokenData
        self.actualID = actualID
        self.travelID = travelID
        self.recordNodeID = recordNodeID
        self.fillColor = fillColor
        self.actualColor = actualColor
        self.styleKey = styleKey ?? [categoryID, title]
            .compactMap { $0 }
            .joined(separator: ".")
    }
}

struct SummaryColor {
    let color: Color
    let opacity: Double

    init(_ color: Color, _ opacity: Double) {
        self.color = color
        self.opacity = opacity
    }
}
