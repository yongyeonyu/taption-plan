#if DEBUG
import SwiftUI

/// 레이아웃 확인용 미리보기. `-nlePreview` 실행 인자로만 열린다.
///
/// 편집기 본문이 파일 예산(1,430줄)에 닿아 있어, 샘플 하루를 들고 있는 이 호스트만
/// 따로 둔다. 실행 인자와 샘플 데이터는 예전과 같다.
struct NLEClipEditorPreviewHost: View {
    @State private var model = AppModel(startsCommerceLocked: false)

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
    private static let sourceIDs: [UUID] = (0..<8).map { _ in UUID() }

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
