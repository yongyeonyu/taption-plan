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
