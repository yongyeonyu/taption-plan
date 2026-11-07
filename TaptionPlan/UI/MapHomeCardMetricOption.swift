import Foundation

/// 공유 카드 고르기 목록의 항목 하나. 달력 지표에 카드 전용 "메모 수"를 더한다(CARD1022N01).
struct MapHomeCardMetricOption: Identifiable, Equatable {
    static let memosID = "memos"

    let id: String
    let systemImage: String
    private let kind: MapHomeCalendarTimeKind?

    private init(kind: MapHomeCalendarTimeKind) {
        id = kind.rawValue
        systemImage = kind.systemImage
        self.kind = kind
    }

    private init(memoID: String) {
        id = memoID
        systemImage = "note.text"
        kind = nil
    }

    init?(id: String) {
        if id == Self.memosID {
            self.init(memoID: id)
        } else if let kind = MapHomeCalendarTimeKind(rawValue: id) {
            self.init(kind: kind)
        } else {
            return nil
        }
    }

    /// 고르기 목록 순서: 달력 지표 다음에 메모 수.
    static let all: [MapHomeCardMetricOption] =
        MapHomeCalendarTimeKind.allCases.map(MapHomeCardMetricOption.init(kind:)) + [MapHomeCardMetricOption(memoID: memosID)]

    func title(_ language: MapHomeLanguage) -> String {
        kind?.title(language) ?? language.text("메모 수", "Memos")
    }

    func valueText(_ number: Double) -> String {
        guard let kind else { return MapHomeCalendarTimeTotalsPolicy.countCellText(count: number) }
        return MapHomeCardMetricSelection.value(for: kind, number: number)
    }
}

extension MapHomeDailyCardContent {
    /// 그날 메모 수와 사진 수를 고르기 값에 채운다. 메모는 시각이 없으면 만든 날짜로 센다.
    /// `photoCount`는 권한이 없으면 0을 돌려준다(시스템 팝업을 띄우지 않는다).
    func addingCounts(day: Date, memos: [ActionMemo], photoCount: Int, calendar: Calendar = .autoupdatingCurrent) -> MapHomeDailyCardContent {
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(24 * 60 * 60)
        let memoCount = memos.filter { memo in
            let when = memo.isTimeless == true ? memo.createdAt : memo.occurredAt
            return when >= start && when < end
        }.count
        var copy = self
        copy.values[MapHomeCardMetricOption.memosID] = Double(memoCount)
        copy.values[MapHomeCalendarTimeKind.photos.rawValue] = Double(photoCount)
        return copy
    }
}
