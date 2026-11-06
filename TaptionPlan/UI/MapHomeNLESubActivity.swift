import CoreGraphics
import CryptoKit
import Foundation

/// 상세 층 클립의 출처(NLE1103A02). 사용자가 남긴 기록과 자동으로 고른 근거를 구분한다.
struct NLESubActivityProvenance: Hashable, Sendable {
    enum Origin: Hashable, Sendable {
        case manual
        case automatic
    }

    let origin: Origin
    let evidence: String

    func label(_ language: MapHomeLanguage) -> String {
        switch origin {
        case .manual: language.text("수동", "Manual")
        case .automatic: language.text("자동 · ", "Auto · ") + evidence
        }
    }
}

struct NLESubActivityInput {
    var segments: [MapHomeTimeRailSegment]
    var actuals: [ActualRecord] = []
    var travel: [TravelSegment] = []
    var calendarEvents: [CalendarRecord] = []
    var calendarTitleDetails: [String: CalendarTitleDetail] = [:]
    var activityCorrections: [UUID: ActivityCorrection] = [:]
    var readings: [SensorReading] = []
    let dayStart: Date
    var asOf: Date = .now
}

/// 대분류 구간 안의 하위 행동을 이미 있는 근거로만 고른다.
///
/// 구간마다 약한 근거부터 분 단위로 칠해 강한 근거가 위에 남는다.
/// 수동 기록 > 통화 > 자동 기록 > 일정 제목 > Watch 행동·Screen Time 메일 앱 순이다.
/// 근거가 없는 시간은 비워 두고, 걷기·정지 같은 모션 원본은 센서 층에만 남긴다.
/// 계산 결과는 화면용 파생 값이라 저장하지 않으며 사용자 기록을 고치지 않는다.
enum NLESubActivityEngine {
    private enum Rank: Int {
        case weakSignal, calendar, record, call, manual
    }

    private struct Candidate {
        let key: String
        let recordID: UUID?
        let title: String
        let categoryID: String
        let behavior: String?
        let startMinute: Int
        let endMinute: Int
        let rank: Rank
        let provenance: NLESubActivityProvenance
    }

    private struct WatchRun {
        let kind: WatchBehaviorKind
        let startMinute: Int
        var endMinute: Int
    }

    /// 일정이 근거가 되는 최소 길이. 체류 판정의 일정 나누기 기준과 같다.
    private static let minimumEventMinutes = 5
    /// 이보다 짧은 Watch 행동은 손목 흔들림으로 보고 쓰지 않는다.
    private static let minimumWatchRunMinutes = 3
    private static let restMinimumSeconds: TimeInterval = 5 * 60
    private static let restMaximumGapSeconds: TimeInterval = 5 * 60
    private static let minimumWatchConfidence = 0.55
    private static let phoneCallDetailID = "activity.phoneCall"
    private static let mailWords = ["mail", "메일", "outlook"]

    static func details(_ input: NLESubActivityInput) -> [MapHomeSectionDetail] {
        let records = input.actuals.compactMap { recordCandidate($0, input: input) }
            + input.travel.map { travelCandidate($0, dayStart: input.dayStart) }
        let events = CalendarTitleClassification
            .counted(input.calendarEvents, stored: input.calendarTitleDetails)
            .filter { !$0.isAllDay && $0.isCancelled != true }
        let watchRuns = watchRuns(input.readings, dayStart: input.dayStart)
        let restRuns = restCandidateRuns(input.readings, dayStart: input.dayStart)
        var usedKeys = Set<String>()
        return input.segments
            .filter { $0.endMinute > $0.startMinute }
            .sorted { $0.startMinute < $1.startMinute }
            .flatMap { segment in
                let candidates = records.filter { applies($0, to: segment) }
                    + events.compactMap { eventCandidate($0, segment: segment, input: input) }
                    + watchRuns.compactMap { watchCandidate($0, segment: segment) }
                    + restRuns.compactMap { restCandidate($0, segment: segment) }
                return paint(candidates, in: segment, usedKeys: &usedKeys)
            }
    }

    /// 근거를 읽기 전에 쓰는 거르개. 대분류를 되풀이하는 상세만 뺀다.
    static func informative(_ details: [MapHomeSectionDetail]) -> [MapHomeSectionDetail] {
        details.filter {
            !isRestatement(categoryID: $0.categoryID, title: $0.title, behavior: $0.behavior)
        }
    }

    /// 대분류 이름 말고는 더 알려 주는 것이 없는 값인가. 근무·수면·식사가 그렇다.
    static func isRestatement(categoryID: String, title: String, behavior: String?) -> Bool {
        if behavior == categoryID { return true }
        if ["unknownStay", "unconfirmed", "unconfirmed-gap"].contains(behavior) { return true }
        let shown = RecordClassificationCatalog.detailTitle(categoryID: categoryID, behavior: behavior) ?? title
        return shown == RecordClassificationCatalog.categories.first { $0.id == categoryID }?.title
    }

    // MARK: - 칠하기

    private static func paint(
        _ candidates: [Candidate],
        in segment: MapHomeTimeRailSegment,
        usedKeys: inout Set<String>
    ) -> [MapHomeSectionDetail] {
        let length = segment.endMinute - segment.startMinute
        var slots = [Int?](repeating: nil, count: length)
        let ordered = candidates.sorted { $0.rank.rawValue < $1.rank.rawValue }
        for (index, candidate) in ordered.enumerated() {
            let lower = max(candidate.startMinute, segment.startMinute)
            let upper = min(candidate.endMinute, segment.endMinute)
            guard lower < upper else { continue }
            for minute in lower..<upper { slots[minute - segment.startMinute] = index }
        }
        var result: [MapHomeSectionDetail] = []
        var cursor = 0
        while cursor < length {
            guard let index = slots[cursor] else {
                cursor += 1
                continue
            }
            var end = cursor + 1
            while end < length, slots[end] == index { end += 1 }
            let candidate = ordered[index]
            let start = segment.startMinute + cursor
            let stop = segment.startMinute + end
            cursor = end
            // 구간 전체를 덮는 수동 분류 기록은 대분류 그 자체다.
            let isWholeSegment = start == segment.startMinute && stop == segment.endMinute
            if isWholeSegment, isRestatement(
                categoryID: candidate.categoryID, title: candidate.title, behavior: candidate.behavior
            ) { continue }
            let isFirstPiece = usedKeys.insert(candidate.key).inserted
            result.append(
                MapHomeSectionDetail(
                    id: (isFirstPiece ? candidate.recordID : nil) ?? stableID("\(candidate.key)|\(start)"),
                    title: candidate.title,
                    categoryID: candidate.categoryID,
                    behavior: candidate.behavior,
                    startMinute: start,
                    endMinute: stop,
                    provenance: candidate.provenance
                )
            )
        }
        return result
    }

    private static func applies(_ candidate: Candidate, to segment: MapHomeTimeRailSegment) -> Bool {
        // 통화·메일은 어느 대분류에서도 실제로 일어난 일이고, 수동 기록은 사용자의 값이라 그대로 둔다.
        candidate.rank == .manual || candidate.rank == .call || candidate.rank == .weakSignal
            || candidate.categoryID == segment.categoryID
    }

    // MARK: - 근거별 후보

    private static func recordCandidate(_ actual: ActualRecord, input: NLESubActivityInput) -> Candidate? {
        let categoryID = RecordAnalysisCategoryPolicy.categoryID(for: actual)
        let minutes = minutes(actual.span(asOf: input.asOf), dayStart: input.dayStart)
        func make(_ title: String, _ rank: Rank, _ evidence: String) -> Candidate {
            Candidate(
                key: actual.id.uuidString, recordID: actual.id, title: title, categoryID: categoryID,
                behavior: actual.behavior, startMinute: minutes.start, endMinute: minutes.end, rank: rank,
                provenance: NLESubActivityProvenance(origin: rank == .manual ? .manual : .automatic, evidence: evidence)
            )
        }
        if ActualRecord.userOwned(actual, activityCorrections: input.activityCorrections) {
            return make(actual.title, .manual, "사용자 기록")
        }
        if TrackingSessionRecordPolicy.isAutomaticSessionArtifact(actual) { return nil }
        switch actual.source {
        case .call:
            return make(actual.title, .call, "CallKit 통화 기록")
        case .appUsage:
            let name = actual.title.lowercased()
            guard mailWords.contains(where: name.contains) else { return nil }
            return make("메일", .weakSignal, "Screen Time \(actual.title) · 시각은 그 시간대 합계")
        case .motion where categoryID != "movement":
            return nil
        default:
            guard !isRestatement(categoryID: categoryID, title: actual.title, behavior: actual.behavior)
            else { return nil }
            return make(actual.title, .record, recordEvidence(actual))
        }
    }

    private static func recordEvidence(_ actual: ActualRecord) -> String {
        actual.evidence.first(where: CalendarTitleClassification.isCalendarEvidence)
            ?? actual.evidence.first
            ?? "자동 기록"
    }

    private static func travelCandidate(_ item: TravelSegment, dayStart: Date) -> Candidate {
        let minutes = minutes(item.span, dayStart: dayStart)
        return Candidate(
            key: item.id.uuidString, recordID: item.id,
            title: MovementPresentation.title(for: item.mode), categoryID: "movement",
            behavior: item.mode.rawValue, startMinute: minutes.start, endMinute: minutes.end, rank: .record,
            provenance: NLESubActivityProvenance(origin: .automatic, evidence: "이동 구간 판정")
        )
    }

    /// 일정은 분류가 대분류와 맞을 때만 쓴다. 분류되지 않은 제목은 업무·수업 안에서만 제목 그대로 보여 준다.
    private static func eventCandidate(
        _ event: CalendarRecord,
        segment: MapHomeTimeRailSegment,
        input: NLESubActivityInput
    ) -> Candidate? {
        let minutes = minutes(event.span, dayStart: input.dayStart)
        guard minutes.end - minutes.start >= minimumEventMinutes,
              minutes.start < segment.endMinute, minutes.end > segment.startMinute else { return nil }
        func make(_ title: String, _ categoryID: String, _ behavior: String?, _ evidence: String) -> Candidate {
            Candidate(
                key: "event|\(event.id)|\(segment.startMinute)", recordID: nil, title: title,
                categoryID: categoryID, behavior: behavior, startMinute: minutes.start, endMinute: minutes.end,
                rank: .calendar, provenance: NLESubActivityProvenance(origin: .automatic, evidence: evidence)
            )
        }
        if let resolved = CalendarTitleClassification.detail(
            for: event.title, stored: input.calendarTitleDetails, at: nil
        ) {
            guard resolved.categoryID == segment.categoryID || resolved.detail.id == phoneCallDetailID,
                  !isRestatement(
                      categoryID: resolved.categoryID, title: resolved.detail.title, behavior: resolved.detail.behavior
                  ) else { return nil }
            return make(resolved.detail.title, resolved.categoryID, resolved.detail.behavior, resolved.evidence)
        }
        guard ["work", "study"].contains(segment.categoryID) else { return nil }
        return make(event.title, segment.categoryID, nil, "일정 '\(event.title)'")
    }

    private static func watchCandidate(_ run: WatchRun, segment: MapHomeTimeRailSegment) -> Candidate? {
        let fits: Bool
        switch run.kind {
        case .typing: fits = ["work", "study"].contains(segment.categoryID)
        default: fits = !["sleep", "movement"].contains(segment.categoryID)
        }
        guard fits, run.startMinute < segment.endMinute, run.endMinute > segment.startMinute else { return nil }
        return Candidate(
            key: "watch|\(run.kind.rawValue)|\(run.startMinute)|\(segment.startMinute)", recordID: nil,
            title: run.kind.title, categoryID: segment.categoryID, behavior: nil,
            startMinute: run.startMinute, endMinute: run.endMinute, rank: .weakSignal,
            provenance: NLESubActivityProvenance(origin: .automatic, evidence: "Apple Watch 행동")
        )
    }

    /// 업무 중 걷지 않고 화면을 켜 둔 시간. 업무로 폰을 쓴 것과 구분되지 않아 후보로만 보여 준다(RST1105A01).
    private static func restCandidate(_ run: Range<Int>, segment: MapHomeTimeRailSegment) -> Candidate? {
        guard segment.categoryID == "work", run.lowerBound < segment.endMinute, run.upperBound > segment.startMinute
        else { return nil }
        return Candidate(
            key: "rest|\(run.lowerBound)|\(segment.startMinute)", recordID: nil,
            title: "휴식 후보", categoryID: segment.categoryID, behavior: nil,
            startMinute: run.lowerBound, endMinute: run.upperBound, rank: .weakSignal,
            provenance: NLESubActivityProvenance(origin: .automatic, evidence: "화면 켜짐 · 걷기 없음")
        )
    }

    static func restCandidateRuns(_ readings: [SensorReading], dayStart: Date) -> [Range<Int>] {
        let ordered = readings
            .filter { $0.screenIsOn == true && !$0.motion.isMovement }
            .sorted { $0.timestamp < $1.timestamp }
        var spans: [(start: Date, end: Date)] = []
        for reading in ordered {
            if let last = spans.last, reading.timestamp.timeIntervalSince(last.end) <= restMaximumGapSeconds {
                spans[spans.count - 1].end = reading.timestamp
            } else {
                spans.append((reading.timestamp, reading.timestamp))
            }
        }
        return spans
            .filter { $0.end.timeIntervalSince($0.start) >= restMinimumSeconds }
            .map { minute($0.start, dayStart)..<max(minute($0.start, dayStart) + 1, minute($0.end, dayStart)) }
    }

    /// 대분류보다 작은 단위를 말해 주는 Watch 행동만 이어 붙인다. 걷기·앉기는 센서 층의 몫이다.
    private static func watchRuns(_ readings: [SensorReading], dayStart: Date) -> [WatchRun] {
        let useful: Set<WatchBehaviorKind> = [.typing, .brushingTeeth, .showering]
        let ordered = readings.filter { $0.behavior != nil }.sorted { $0.timestamp < $1.timestamp }
        var runs: [WatchRun] = []
        for (index, reading) in ordered.enumerated() {
            guard let kind = reading.behavior.flatMap(WatchBehaviorKind.init(rawValue:)), useful.contains(kind),
                  (reading.behaviorConfidenceScore ?? 0.5) >= minimumWatchConfidence else { continue }
            let start = minute(reading.timestamp, dayStart)
            let next = index + 1 < ordered.count ? minute(ordered[index + 1].timestamp, dayStart) : start + 1
            let end = min(max(next, start + 1), start + MapHomeNLESensorEvidence.maximumHoldMinutes)
            if let last = runs.last, last.kind == kind, last.endMinute >= start {
                runs[runs.count - 1].endMinute = max(last.endMinute, end)
            } else {
                runs.append(WatchRun(kind: kind, startMinute: start, endMinute: end))
            }
        }
        return runs.filter { $0.endMinute - $0.startMinute >= minimumWatchRunMinutes }
    }

    // MARK: - 시각·식별자

    private static func minutes(_ span: TimeSpan, dayStart: Date) -> (start: Int, end: Int) {
        let start = minute(span.start, dayStart)
        return (start, max(start, minute(span.end, dayStart)))
    }

    private static func minute(_ date: Date, _ dayStart: Date) -> Int {
        min(max(Int((date.timeIntervalSince(dayStart) / 60).rounded()), 0), NLETrack.dayMinutes)
    }

    private static func stableID(_ key: String) -> UUID {
        let bytes = Array(SHA256.hash(data: Data(key.utf8)).prefix(16))
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

/// 센서 구간에서 상세 클립이 가리지 않는 시간(NLE1103A02).
enum NLESensorLabelPlacement {
    static func freeRanges(start: Int, end: Int, occupied: [NLEClip]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var cursor = start
        for clip in occupied.sorted(by: { $0.startMinute < $1.startMinute })
        where clip.startMinute < end && clip.endMinute > start {
            if clip.startMinute > cursor { ranges.append(cursor..<clip.startMinute) }
            cursor = max(cursor, clip.endMinute)
        }
        if cursor < end { ranges.append(cursor..<end) }
        return ranges
    }
}

/// 터치가 끝났을 때 대분류 클립 선택을 풀지 정한다(NLE1103A03).
enum NLESelectionTapPolicy {
    /// 이만큼(가로+세로 pt) 움직이면 더 이상 탭이 아니다.
    static let slop: CGFloat = 4

    static func hasLeftSlop(translation: CGSize) -> Bool {
        abs(translation.width) + abs(translation.height) >= slop
    }

    /// 터치 시작에 이미 고른 클립을 그대로 다시 눌렀을 때만 푼다.
    /// 움직였거나, 경계를 다듬었거나, 집어 들었으면 탭이 아니다.
    static func clearsSelection(
        selectedAtTouchStart: String?,
        touchedClipID: String?,
        isMainLaneTouch: Bool,
        leftSlop: Bool,
        didEdit: Bool,
        isLifted: Bool
    ) -> Bool {
        guard isMainLaneTouch, !leftSlop, !didEdit, !isLifted, let touchedClipID else { return false }
        return touchedClipID == selectedAtTouchStart
    }
}
