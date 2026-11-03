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
        let today = Calendar.autoupdatingCurrent.startOfDay(for: Date())
        NLEDayWindow.previewDays[today] = NLEDayInput(
            segments: Self.segments,
            details: NLESubActivityEngine.details(Self.sampleEvidence(dayStart: today))
        )
        NLEDayWindow.previewPlaces[today] = Self.samplePlaces(dayStart: today)
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

    /// 업무 구간의 근거 예시. 화면과 같은 계산(`NLESubActivityEngine`)을 지나 상세 층이 된다.
    /// 07:00–08:00과 09:50–10:00처럼 근거가 없는 시간은 비어야 한다.
    private static func sampleEvidence(dayStart: Date) -> NLESubActivityInput {
        func date(_ minute: Int) -> Date { dayStart.addingTimeInterval(Double(minute) * 60) }
        func record(_ title: String, _ behavior: String?, _ start: Int, _ end: Int, source: ActualSource, evidence: [String] = []) -> ActualRecord {
            ActualRecord(
                id: UUID(), planID: nil, routineID: nil, title: title, categoryID: "work",
                startedAt: date(start), endedAt: date(end), source: source, confidence: .medium,
                createdAt: date(start), behavior: behavior, evidence: evidence,
                manuallyCorrected: source == .manual
            )
        }
        func event(_ title: String, _ start: Int, _ end: Int) -> CalendarRecord {
            CalendarRecord(
                id: title, calendarID: "preview", title: title, span: TimeSpan(start: date(start), end: date(end)),
                isAllDay: false, calendarTitle: "미리보기", calendarColorHex: nil, sourceTitle: nil
            )
        }
        return NLESubActivityInput(
            segments: segments,
            actuals: [
                record("근무", "work", 420, 720, source: .location, evidence: ["자주가는 곳: 회사"]),
                record("휴식", "stationary", 570, 590, source: .location, evidence: ["자주가는 곳: 회사"]),
                record("통화", "phoneCall", 660, 680, source: .call),
                record("코드 리뷰", nil, 690, 720, source: .manual),
            ],
            calendarEvents: [event("주간 회의", 480, 540), event("메일 정리", 600, 650)],
            dayStart: dayStart
        )
    }

    /// 장소 줄 예시.
    private static func samplePlaces(dayStart: Date) -> [PlaceStay] {
        func stay(_ key: String, _ name: String, _ start: Int, _ end: Int) -> PlaceStay {
            PlaceStay(
                placeKey: key, displayName: name,
                span: TimeSpan(
                    start: dayStart.addingTimeInterval(Double(start) * 60),
                    end: dayStart.addingTimeInterval(Double(end) * 60)
                ),
                confidence: .high
            )
        }
        return [stay("home", "집", 0, 470), stay("office", "회사", 485, 960), stay("home", "집", 1_020, 1_440)]
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
