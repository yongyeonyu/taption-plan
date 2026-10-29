import Foundation

/// 하루치로 읽은 구간과 상세활동. 편집기가 날마다 하나씩 받는다.
struct NLEDayInput: Equatable {
    var segments: [MapHomeTimeRailSegment]
    var details: [MapHomeSectionDetail]
}

/// 하루치 클립. 대분류 줄과 상세활동 줄.
struct NLEDayClips: Equatable {
    var main: [NLEClip]
    var sub: [NLEClip]
}

/// 클립 편집기가 지금 들고 있는 날들(NLE1029A02).
///
/// 기준일 00:00이 0분이고, 지난 날은 음수 분으로 앞에 이어진다(어제 = −1,440…0).
/// 위로 넘기면 끝없이 전날을 읽어 붙이고, 자정을 넘는 기록은 클립 하나로 잇는다.
/// 기준일 24:00 아래로는 내려가지 않는다. 계산은 모두 순수해서 그대로 시험한다.
struct NLEDayWindow: Equatable {
    let baseDate: Date
    /// 기준일을 포함해 읽어 둔 날 수.
    let loadedDays: Int
    var calendar: Calendar

    init(baseDate: Date, loadedDays: Int = 1, calendar: Calendar = .autoupdatingCurrent) {
        self.baseDate = baseDate
        self.loadedDays = max(1, loadedDays)
        self.calendar = calendar
    }

    var rangeStartMinute: Int { (1 - loadedDays) * NLETrack.dayMinutes }
    var rangeEndMinute: Int { NLETrack.dayMinutes }

    /// 다음에 읽을 날: 가장 이른 날의 전날.
    var nextEarlierDate: Date {
        calendar.date(byAdding: .day, value: -loadedDays, to: calendar.startOfDay(for: baseDate))
            ?? baseDate
    }

    /// 다음에 읽을 날의 오프셋(기준일 = 0, 어제 = −1).
    var nextEarlierOffset: Int { -loadedDays }

    /// 화면 맨 위가 읽어 둔 범위의 시작에 한 화면 안으로 다가왔는가.
    static func needsEarlierDay(
        visibleStartMinute: Double,
        visibleMinutes: Double,
        rangeStartMinute: Int
    ) -> Bool {
        visibleStartMinute < Double(rangeStartMinute) + visibleMinutes
    }

    // MARK: - 눈금

    /// 그 분이 속한 날(기준일 = 0, 어제 = −1). 음수도 내림으로 나눈다.
    static func dayIndex(_ minute: Int) -> Int {
        Int((Double(minute) / Double(NLETrack.dayMinutes)).rounded(.down))
    }

    /// 그 날 안에서의 분(0…1,439).
    static func minuteOfDay(_ minute: Int) -> Int {
        minute - dayIndex(minute) * NLETrack.dayMinutes
    }

    /// 24시간으로 감은 시(0…23). −60은 23이다.
    static func wrappedHour(_ minute: Int) -> Int {
        minuteOfDay(minute) / 60
    }

    /// 자정 줄에 붙는 날짜 "10/28".
    static func dayLabel(
        dayIndex: Int,
        baseDate: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> String {
        let day = calendar.date(byAdding: .day, value: dayIndex, to: calendar.startOfDay(for: baseDate))
            ?? baseDate
        let parts = calendar.dateComponents([.month, .day], from: day)
        return "\(parts.month ?? 0)/\(parts.day ?? 0)"
    }

    // MARK: - 클립

    /// 하루 구간·상세활동을 그 날의 오프셋만큼 옮긴 클립으로 세운다.
    @MainActor
    static func clips(
        segments: [MapHomeTimeRailSegment],
        details: [MapHomeSectionDetail],
        dayOffset: Int
    ) -> NLEDayClips {
        NLEDayClips(
            main: MapHomeNLEClipEditor.makeMainTrack(segments: segments, dayOffset: dayOffset).clips,
            sub: MapHomeNLEClipEditor.makeSubTrack(details: details, segments: segments, dayOffset: dayOffset).clips
        )
    }

    /// 하루치 클립을 트랙 앞에 잇는다. 범위가 하루만큼 앞으로 넓어지고, 이미 고친 클립은 그대로다.
    static func prepending(_ dayClips: [NLEClip], to track: NLETrack) -> NLETrack {
        joinAcrossMidnight(
            NLETrack(
                clips: dayClips + track.clips,
                rangeStartMinute: track.rangeStartMinute - NLETrack.dayMinutes,
                rangeEndMinute: track.rangeEndMinute,
                fillsGaps: track.fillsGaps
            )
        )
    }

    /// 자정에서 맞닿고 같은 원본 기록을 가리키는 구간을 하나로 잇는다.
    ///
    /// 시간선은 자정을 넘는 기록(수면 23:00–07:00)을 날마다 잘라 두 조각으로 준다.
    /// 그대로 두면 적용할 때 요청이 둘 나가 기록이 겹치므로, 원본 구간을 먼저 하나로
    /// 합치고 그 위의 클립도 이어 붙인다. 한쪽을 이미 고쳤어도 구간은 합쳐진다.
    static func joinAcrossMidnight(_ track: NLETrack) -> NLETrack {
        let parents = Set(track.clips.map(\.parent)).sorted { $0.startMinute < $1.startMinute }
        var union: [NLEClipParent: NLEClipParent] = [:]
        var run: [NLEClipParent] = []
        for parent in parents {
            if let last = run.last, touchesAtMidnight(last, parent) {
                run.append(parent)
            } else {
                record(run, into: &union)
                run = [parent]
            }
        }
        record(run, into: &union)
        guard !union.isEmpty else { return track }
        let reparented = track.clips.map { clip in
            union[clip.parent].map { reparent(clip, to: $0) } ?? clip
        }
        return NLETrack(
            clips: joinedClips(reparented),
            rangeStartMinute: track.rangeStartMinute,
            rangeEndMinute: track.rangeEndMinute,
            fillsGaps: track.fillsGaps
        )
    }

    private static func touchesAtMidnight(_ a: NLEClipParent, _ b: NLEClipParent) -> Bool {
        a.endMinute == b.startMinute
            && a.endMinute.isMultiple(of: NLETrack.dayMinutes)
            && !a.sourceIDs.isEmpty
            && !Set(a.sourceIDs).isDisjoint(with: b.sourceIDs)
            && a.option.categoryID == b.option.categoryID
    }

    /// 맞닿은 구간 묶음을 하나의 구간으로 적는다. 하나뿐이면 적을 것이 없다.
    private static func record(_ run: [NLEClipParent], into union: inout [NLEClipParent: NLEClipParent]) {
        guard let first = run.first, let last = run.last, run.count > 1 else { return }
        let joined = NLEClipParent(
            startMinute: first.startMinute,
            endMinute: last.endMinute,
            sourceIDs: Array(Set(run.flatMap(\.sourceIDs))).sorted { $0.uuidString < $1.uuidString },
            option: first.option,
            fillOption: first.fillOption
        )
        for parent in run { union[parent] = joined }
    }

    private static func reparent(_ clip: NLEClip, to parent: NLEClipParent) -> NLEClip {
        NLEClip(
            id: clip.id,
            option: clip.option,
            startMinute: clip.startMinute,
            endMinute: clip.endMinute,
            parent: parent,
            origin: clip.origin
        )
    }

    /// 같은 구간·같은 분류로 자정에서 맞닿은 클립을 하나로 붙인다.
    private static func joinedClips(_ clips: [NLEClip]) -> [NLEClip] {
        var result: [NLEClip] = []
        for clip in clips.sorted(by: { $0.startMinute < $1.startMinute }) {
            if let last = result.last,
               last.endMinute == clip.startMinute,
               last.endMinute.isMultiple(of: NLETrack.dayMinutes),
               last.parent == clip.parent,
               last.option == clip.option {
                result[result.count - 1] = NLEClip(
                    id: last.id,
                    option: last.option,
                    startMinute: last.startMinute,
                    endMinute: clip.endMinute,
                    parent: last.parent,
                    origin: NLEClipOrigin(
                        startMinute: last.origin.startMinute,
                        endMinute: last.origin.endMinute == clip.origin.startMinute
                            ? clip.origin.endMinute
                            : last.origin.endMinute,
                        option: last.origin.option
                    )
                )
                continue
            }
            result.append(clip)
        }
        return result
    }

    // MARK: - 읽기

    #if DEBUG
    /// 미리보기(`-nlePreviewMultiDay`)가 심어 두는 지난 날. 키는 그 날의 00:00이다.
    @MainActor static var previewDays: [Date: NLEDayInput] = [:]
    #endif

    /// 그 날의 구간·상세활동을 기준일과 같은 방법으로 읽는다. 원본은 고치지 않는다.
    @MainActor
    static func loadDay(model: AppModel, date: Date) async -> NLEDayInput {
        let calendar = Calendar.autoupdatingCurrent
        let dayStart = calendar.startOfDay(for: date)
        #if DEBUG
        if let preview = previewDays[dayStart] { return preview }
        #endif
        let day = await model.planDayDataSnapshot(for: date, forceReload: false)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)
            ?? dayStart.addingTimeInterval(24 * 60 * 60)
        return NLEDayInput(
            segments: MapHomeTimeRailSegmentEngine.segments(from: day.actuals, travel: day.travel, on: date),
            details: MapHomeSectionDetailEngine.dayDetails(
                actuals: day.actuals, travel: day.travel, dayStart: dayStart, dayEnd: dayEnd, asOf: .now
            )
        )
    }
}
