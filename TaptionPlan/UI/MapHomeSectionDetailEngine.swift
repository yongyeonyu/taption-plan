import Foundation

/// 시간선 위 한 구간의 상세활동 한 줄. 원본 기록 하나(또는 이동 구간 하나)가
/// 하루의 몇 분을 차지하는지 담는다.
struct MapHomeSectionDetail: Identifiable, Hashable {
    let id: UUID
    let title: String
    let categoryID: String
    let behavior: String?
    let startMinute: Int
    let endMinute: Int
}

/// 원본 기록을 상세활동 목록으로 바꾼다.
///
/// 시간선의 대분류 구간 하나는 원본 기록 하나가 아니라 **여러 기록을 합친 것**일 수
/// 있다(업무 세 건이 07:00–12:00 한 덩어리가 되는 식). 그래서 상세활동은
/// "구간이 품은 기록들"이며, 구간 하나가 기록 하나로 된 경우에만 그 기록이 곧 구간이라
/// 상세에서 뺀다. 예전에는 구간의 `sourceIDs`를 **전부** 빼서, 합쳐진 구간의 상세가
/// 통째로 비었다(2026-10-28).
enum MapHomeSectionDetailEngine {
    private struct DuplicateKey: Hashable {
        let categoryID: String
        let title: String
        let behavior: String?
        let startMinute: Int
        let endMinute: Int
    }

    private struct Candidate {
        let detail: MapHomeSectionDetail
        let priority: Int
        let tieBreak: String

        var key: DuplicateKey {
            DuplicateKey(
                categoryID: detail.categoryID,
                title: detail.title,
                behavior: detail.behavior,
                startMinute: detail.startMinute,
                endMinute: detail.endMinute
            )
        }
    }

    /// 한 구간의 상세활동. 구간 밖으로 넘어가는 부분은 잘라낸다.
    static func details(
        actuals: [ActualRecord],
        travel: [TravelSegment],
        segment: MapHomeTimeRailSegment,
        dayStart: Date,
        dayEnd: Date,
        asOf: Date
    ) -> [MapHomeSectionDetail] {
        let calendar = Calendar.autoupdatingCurrent
        guard let segmentStart = calendar.date(
            byAdding: .minute,
            value: segment.startMinute,
            to: dayStart
        ), let segmentEnd = calendar.date(
            byAdding: .minute,
            value: segment.endMinute,
            to: dayStart
        ) else { return [] }
        return makeDetails(
            actuals: actuals,
            travel: travel,
            span: TimeSpan(start: segmentStart, end: segmentEnd),
            ownSourceIDs: segment.sourceIDs,
            dayStart: dayStart,
            dayEnd: dayEnd,
            asOf: asOf
        )
    }

    /// 하루 전체의 상세활동. **구간 경계에서 자르지 않는다.**
    ///
    /// 예전에는 구간마다 잘라 만든 목록을 id로 중복 제거해 합쳤다. 그래서 09:50–10:20
    /// 기록이 10:00 경계에서 잘린 앞토막만 남고 뒤쪽 20분이 사라졌다(2026-10-28).
    /// 하루 단위로 한 번만 만들면 기록이 제 길이 그대로 남는다.
    static func dayDetails(
        actuals: [ActualRecord],
        travel: [TravelSegment],
        dayStart: Date,
        dayEnd: Date,
        asOf: Date
    ) -> [MapHomeSectionDetail] {
        makeDetails(
            actuals: actuals,
            travel: travel,
            span: TimeSpan(start: dayStart, end: dayEnd),
            ownSourceIDs: [],
            dayStart: dayStart,
            dayEnd: dayEnd,
            asOf: asOf
        )
    }

    private static func makeDetails(
        actuals: [ActualRecord],
        travel: [TravelSegment],
        span: TimeSpan,
        ownSourceIDs: [UUID],
        dayStart: Date,
        dayEnd: Date,
        asOf: Date
    ) -> [MapHomeSectionDetail] {
        var candidates = actuals.compactMap { actual -> Candidate? in
            // 한 기록짜리 구간은 그 기록이 곧 구간이라 상세에서 뺀다. 여러 기록을 합친 구간은 그 기록들이 상세활동이다.
            guard !(ownSourceIDs.count == 1 && ownSourceIDs.contains(actual.id)),
                  let clipped = actual.span(asOf: asOf).intersection(with: span),
                  clipped.start < dayEnd,
                  clipped.end > dayStart
            else { return nil }
            let minutes = clippedMinutes(clipped, dayStart: dayStart)
            let detail = MapHomeSectionDetail(
                id: actual.id,
                title: actual.title,
                categoryID: RecordAnalysisCategoryPolicy.categoryID(for: actual),
                behavior: actual.behavior,
                startMinute: minutes.start,
                endMinute: minutes.end
            )
            return Candidate(
                detail: detail,
                priority: actualPriority(actual),
                tieBreak: "actual|\(actual.source.rawValue)|\(actual.id.uuidString)"
            )
        }
        candidates.append(contentsOf: travel.compactMap { item -> Candidate? in
            guard !(ownSourceIDs.count == 1 && ownSourceIDs.contains(item.id)),
                  let clipped = item.span.intersection(with: span),
                  clipped.start < dayEnd,
                  clipped.end > dayStart
            else { return nil }
            let minutes = clippedMinutes(clipped, dayStart: dayStart)
            let detail = MapHomeSectionDetail(
                id: item.id,
                title: AppLanguagePreference.text(
                    korean: "\(MovementPresentation.title(for: item.mode)) 탑승",
                    english: "\(MovementPresentation.englishTitle(for: item.mode)) ride"
                ),
                categoryID: "movement",
                behavior: item.mode.rawValue,
                startMinute: minutes.start,
                endMinute: minutes.end
            )
            return Candidate(
                detail: detail,
                priority: 0,
                tieBreak: "travel|\(item.mode.rawValue)|\(item.id.uuidString)"
            )
        })

        var selected: [DuplicateKey: Candidate] = [:]
        for candidate in candidates {
            guard let current = selected[candidate.key] else {
                selected[candidate.key] = candidate
                continue
            }
            if isPreferred(candidate, over: current) {
                selected[candidate.key] = candidate
            }
        }
        return selected.values.map(\.detail).sorted { lhs, rhs in
            if lhs.startMinute != rhs.startMinute {
                return lhs.startMinute < rhs.startMinute
            }
            if lhs.endMinute != rhs.endMinute {
                return lhs.endMinute < rhs.endMinute
            }
            if lhs.categoryID != rhs.categoryID {
                return lhs.categoryID < rhs.categoryID
            }
            if lhs.title != rhs.title {
                return lhs.title < rhs.title
            }
            if lhs.behavior != rhs.behavior {
                return (lhs.behavior ?? "") < (rhs.behavior ?? "")
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    private static func actualPriority(_ actual: ActualRecord) -> Int {
        if actual.manuallyCorrected || actual.source == .manual {
            return 4
        }
        switch actual.source {
        case .healthKit, .appleWatch:
            return 3
        case .motion:
            return 2
        case .location:
            return 1
        default:
            return 0
        }
    }

    private static func isPreferred(
        _ candidate: Candidate,
        over current: Candidate
    ) -> Bool {
        if candidate.priority != current.priority {
            return candidate.priority > current.priority
        }
        return candidate.tieBreak < current.tieBreak
    }

    /// 분 단위로 **반올림**한다.
    ///
    /// 예전에는 시작을 내림·끝을 올림해서 기록을 감싸도록 부풀렸다. 그러면 09:45:20에
    /// 끝나는 기록이 09:46까지, 09:45:20에 시작하는 다음 기록이 09:45부터 차지해
    /// 맞닿은 두 상세가 1분씩 겹쳐 보였다(2026-10-28). 같은 시각은 같은 분으로
    /// 반올림되므로, 맞닿은 경계는 반올림해도 그대로 맞닿는다.
    private static func clippedMinutes(
        _ span: TimeSpan,
        dayStart: Date
    ) -> (start: Int, end: Int) {
        let start = min(
            1_440,
            max(0, Int((span.start.timeIntervalSince(dayStart) / 60).rounded()))
        )
        let end = min(
            1_440,
            max(start + 1, Int((span.end.timeIntervalSince(dayStart) / 60).rounded()))
        )
        return (start, end)
    }
}
