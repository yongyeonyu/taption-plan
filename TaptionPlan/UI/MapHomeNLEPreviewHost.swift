#if DEBUG
import SwiftUI

/// 레이아웃 확인용 미리보기. `-nlePreview` 실행 인자로만 열린다.
///
/// 편집기 본문이 파일 예산(1,430줄)에 닿아 있어, 샘플 하루를 들고 있는 이 호스트만
/// 따로 둔다. 실행 인자와 샘플 데이터는 예전과 같다.
struct NLEClipEditorPreviewHost: View {
    @State private var model = AppModel(startsCommerceLocked: false)

    /// `-nlePreviewMultiDay`: 어제를 심어 둔다. 수면이 어제 23:00에서 오늘 07:00까지
    /// 한 기록(같은 sourceID)으로 이어져, 위로 넘기면 클립 하나로 보여야 한다(NLE1029A02).
    init() {
        guard ProcessInfo.processInfo.arguments.contains("-nlePreviewMultiDay") else { return }
        let calendar = Calendar.autoupdatingCurrent
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: Date()))
        else { return }
        NLEDayWindow.previewDays[yesterday] = NLEDayInput(segments: Self.previousDaySegments, details: [])
    }

    var body: some View {
        MapHomeNLEClipEditor(
            model: model,
            language: .korean,
            date: Date(),
            segments: Self.segments,
            details: Self.details,
            focusMinute: 600,
            initialMinuteHeight: ProcessInfo.processInfo.arguments.contains("-nleZoom")
                ? 2.6
                : nil,
            onSaved: {}
        )
    }

    /// 샘플 구간마다 붙는 원본 기록 ID.
    ///
    /// `static let`이라 화면을 다시 그려도 값이 바뀌지 않는다. 값이 없으면 모든 구간이
    /// '기록 없는 시간'이 되어 전체 덮기가 아무것도 바꾸지 못한다 — 실제 하루는 센서
    /// 기록 위에 서 있으므로 미리보기도 같은 조건에 둔다.
    private static let sourceIDs: [UUID] = (0..<10).map { _ in UUID() }

    /// 어제 샘플. 마지막 수면(23:00–24:00)은 오늘 첫 수면과 같은 기록이다.
    private static var previousDaySegments: [MapHomeTimeRailSegment] {
        let sources = sourceIDs
        return [
            MapHomeTimeRailSegment(
                startMinute: 540, endMinute: 1_080, categoryID: "work", title: "업무",
                sourceIDs: [sources[8]]
            ),
            MapHomeTimeRailSegment(
                startMinute: 1_080, endMinute: 1_320, categoryID: "hobby", title: "취미",
                sourceIDs: [sources[9]]
            ),
            MapHomeTimeRailSegment(
                startMinute: 1_320, endMinute: 1_440, categoryID: "sleep", title: "수면",
                sourceIDs: [sources[0]]
            ),
        ]
    }

    private static var segments: [MapHomeTimeRailSegment] {
        let sources = sourceIDs
        return [
            MapHomeTimeRailSegment(
                startMinute: 0, endMinute: 420, categoryID: "sleep", title: "수면",
                sourceIDs: [sources[0]]
            ),
            MapHomeTimeRailSegment(
                startMinute: 420, endMinute: 720, categoryID: "work", title: "업무",
                sourceIDs: [sources[1]]
            ),
            MapHomeTimeRailSegment(
                startMinute: 720, endMinute: 780, categoryID: "eating", title: "식사",
                sourceIDs: [sources[2]]
            ),
            MapHomeTimeRailSegment(
                startMinute: 780, endMinute: 960, categoryID: "activity", title: "일상",
                sourceIDs: [sources[3]]
            ),
            MapHomeTimeRailSegment(
                startMinute: 960, endMinute: 1_020, categoryID: "movement", title: "이동",
                sourceIDs: [sources[4]]
            ),
            MapHomeTimeRailSegment(
                startMinute: 1_020, endMinute: 1_140, categoryID: "activity", title: "일상",
                sourceIDs: [sources[5]]
            ),
            MapHomeTimeRailSegment(
                startMinute: 1_140, endMinute: 1_320, categoryID: "hobby", title: "취미",
                sourceIDs: [sources[6]]
            ),
            MapHomeTimeRailSegment(
                startMinute: 1_320, endMinute: 1_440, categoryID: "sleep", title: "수면",
                sourceIDs: [sources[7]]
            ),
        ]
    }

    private static var details: [MapHomeSectionDetail] {
        [
            MapHomeSectionDetail(
                id: UUID(), title: "회의", categoryID: "work",
                behavior: nil, startMinute: 480, endMinute: 540
            ),
            MapHomeSectionDetail(
                id: UUID(), title: "메일", categoryID: "work",
                behavior: nil, startMinute: 600, endMinute: 660
            ),
        ]
    }
}
#endif
