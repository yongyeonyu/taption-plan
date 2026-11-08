import Foundation
import TaptionPlanEngine

/// 메모는 구간이 아니라 순간이다. 시간표는 구간만 그릴 수 있으므로 순간을
/// 표식으로 바꾸고, 한 화면에서 서로 구분되지 않을 만큼 붙은 표식은 하나로
/// 합친다. 화소보다 얇은 조각을 수백 개 그리면 화면이 멈춘다는 사실은 눈금판
/// 띠에서 이미 배웠으므로 기준값도 그 띠와 같은 것
/// (`RecordClockDetailEngine.minimumArcFraction`)을 쓴다.
enum MemoTimelineEngine {
    /// 항목에 딸리지 않은 메모가 갖는 분류. 곧 시간표 메모 줄의 id 다.
    static let categoryID = TimelineRowKind.memo.rawValue

    /// 표식 하나의 기본 길이. 하루의 0.4%는 약 6분이다.
    static let markerDuration: TimeInterval =
        86_400 * RecordClockDetailEngine.minimumArcFraction

    /// 보이는 기간이 넓을수록 더 많이 합친다. 주는 약 40분, 월은 약 3시간,
    /// 년은 약 하루 반 안에 있는 메모가 표식 하나로 모인다.
    static func clusterInterval(
        visibleDuration: TimeInterval
    ) -> TimeInterval {
        max(
            markerDuration,
            visibleDuration * RecordClockDetailEngine.minimumArcFraction
        )
    }

    /// 시간표 메모 줄에 그려질 표식. 여러 메모가 모였으면 `memoIDs` 가 그
    /// 전부를 들고 있어 탭 한 번으로 묶음을 열 수 있다.
    struct Marker: Identifiable, Equatable, Sendable {
        let id: UUID
        let span: TimeSpan
        let memoIDs: [UUID]
        let title: String

        var count: Int { memoIDs.count }
    }

    static func markers(
        from memos: [ActionMemo],
        in span: TimeSpan,
        visibleDuration: TimeInterval
    ) -> [Marker] {
        let interval = clusterInterval(visibleDuration: visibleDuration)
        let sorted = memos
            .filter { $0.occurredAt >= span.start && $0.occurredAt < span.end }
            .sorted {
                $0.occurredAt == $1.occurredAt
                    ? $0.id.uuidString < $1.id.uuidString
                    : $0.occurredAt < $1.occurredAt
            }
        var result: [Marker] = []
        var grouped: [ActionMemo] = []
        for memo in sorted {
            // 앞 메모와의 간격이 표식 하나 길이보다 좁으면 같은 자리를 다시
            // 칠할 뿐이므로 이어 붙인다. 눈금판 띠의 합치기 규칙과 같다.
            if let previous = grouped.last,
               memo.occurredAt.timeIntervalSince(previous.occurredAt)
                   < interval {
                grouped.append(memo)
                continue
            }
            if let marker = marker(grouped, interval: interval) {
                result.append(marker)
            }
            grouped = [memo]
        }
        if let marker = marker(grouped, interval: interval) {
            result.append(marker)
        }
        return result
    }

    /// 표식을 탭했을 때 열 메모. 표식이 덮은 구간은 반열림이라 이웃 표식의
    /// 메모를 끌어오지 않는다.
    static func memoIDs(
        in span: TimeSpan,
        from memos: [ActionMemo]
    ) -> [UUID] {
        memos
            .filter { $0.occurredAt >= span.start && $0.occurredAt < span.end }
            .sorted { $0.occurredAt < $1.occurredAt }
            .map(\.id)
    }

    /// 하단 메모 카드가 늘어놓는 메모. 표식과 달리 합치지 않고 시간 순서
    /// 그대로 보여 준다. 구간이 반열림인 것은 표식과 같다.
    static func detailList(
        in span: TimeSpan,
        from memos: [ActionMemo]
    ) -> [ActionMemo] {
        memos
            .filter { $0.occurredAt >= span.start && $0.occurredAt < span.end }
            .sorted {
                $0.occurredAt == $1.occurredAt
                    ? $0.createdAt < $1.createdAt
                    : $0.occurredAt < $1.occurredAt
            }
    }

    /// 메모를 남길 순간. 시간표가 지금을 비추고 있으면 지금이고, 지난 기간을
    /// 펼쳐 둔 상태라면 화면 한가운데다. 어제에 남긴 메모는 어제에 남는다.
    static func entryDate(now: Date, visibleSpan: TimeSpan) -> Date {
        guard now >= visibleSpan.start, now < visibleSpan.end else {
            return visibleSpan.start
                .addingTimeInterval(visibleSpan.duration / 2)
        }
        return now
    }

    static func title(count: Int, firstText: String) -> String {
        count <= 1
            ? firstText.trimmingCharacters(in: .whitespacesAndNewlines)
            : "메모 \(count)개"
    }

    private static func marker(
        _ memos: [ActionMemo],
        interval: TimeInterval
    ) -> Marker? {
        guard let first = memos.first, let last = memos.last else {
            return nil
        }
        return Marker(
            id: first.id,
            span: TimeSpan(
                start: first.occurredAt,
                end: last.occurredAt.addingTimeInterval(interval)
            ),
            memoIDs: memos.map(\.id),
            title: title(count: memos.count, firstText: first.text)
        )
    }
}
