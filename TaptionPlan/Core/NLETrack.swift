import CoreGraphics
import Foundation

/// NLE 타임라인의 클립 하나.
///
/// 대분류 클립은 하루 24시간을 빈틈없이 채운다. 편집은 클립이 딛고 선 원본
/// 구간(`parent`) 밖으로 나가지 않는다. 그래야 센서에 없는 시간을 지어내지 않는다.
struct NLEClip: Identifiable, Hashable, Sendable {
    /// 타임라인 안에서 선택을 따라다니는 고정 ID. 자르면 뒤 조각이 새 ID를 받는다.
    let id: String
    var option: ActivityCorrectionOption
    var startMinute: Int
    var endMinute: Int
    let parent: NLEClipParent
    /// 타임라인을 만들 때의 모습. 커밋할 때 바뀐 클립만 골라내는 기준이다.
    let origin: NLEClipOrigin

    var lengthMinutes: Int { max(0, endMinute - startMinute) }

    /// 원본 기록이 없는 빈 시간. 자동 기록이 닿지 않은 구간이다.
    var isGap: Bool { option.categoryID == "unconfirmed" }

    var isDirty: Bool {
        startMinute != origin.startMinute
            || endMinute != origin.endMinute
            || option.categoryID != origin.option.categoryID
            || option.title != origin.option.title
            || option.behavior != origin.option.behavior
    }

    var spanMinutes: Range<Int> { startMinute..<max(startMinute, endMinute) }

    func contains(minute: Int) -> Bool {
        startMinute <= minute && minute < endMinute
    }
}

/// 클립이 딛고 선 원본 구간. 같은 구간의 클립들은 한 번에 커밋된다.
struct NLEClipParent: Hashable, Sendable {
    let startMinute: Int
    let endMinute: Int
    /// 원본 기록 ID. 빈 시간은 비어 있다.
    let sourceIDs: [UUID]
    /// 이 구간이 처음에 보이던 분류. 서브클립을 지우면 여기로 돌아간다.
    let option: ActivityCorrectionOption
    /// 클립을 지우거나 줄여서 비는 자리를 무엇으로 채울지.
    /// 대분류는 미확인, 서브클립은 상위 대분류다.
    let fillOption: ActivityCorrectionOption

    var lengthMinutes: Int { max(0, endMinute - startMinute) }

    var stableKey: String {
        [
            String(startMinute),
            String(endMinute),
            sourceIDs.map(\.uuidString).sorted().joined(separator: ","),
        ].joined(separator: "|")
    }
}

struct NLEClipOrigin: Hashable, Sendable {
    let startMinute: Int
    let endMinute: Int
    let option: ActivityCorrectionOption
}

enum NLEClipEdge: String, Sendable {
    case start
    case end
}

/// 하루(또는 한 구간)를 클립으로 이어 붙인 NLE 타임라인.
///
/// 동영상 편집기와 같은 규칙을 쓴다.
/// * 클립은 겹치지 않고, 자르거나 옮기면 빈 자리는 미확인으로 남는다.
/// * 옮기기·다듬기는 원본 구간 안에서만 일어난다. 경계를 맞물려 미는 롤만 예외로,
///   넘어선 시간은 그 시간을 소유한 원본 구간의 요청에 조각으로 실린다.
/// * 편집 결과는 원본 구간마다 `cover` 요청 하나로 커밋된다.
struct NLETrack: Hashable, Sendable {
    static let dayMinutes = 1_440
    static let minimumClipMinutes = 1

    private(set) var clips: [NLEClip]
    let rangeStartMinute: Int
    let rangeEndMinute: Int
    /// 빈 자리를 미확인 클립으로 채울지. 하루 타임라인은 채우고, 서브클립 줄은 비워 둔다.
    let fillsGaps: Bool
    /// 합치기로 클립이 모두 사라진 원본 구간. 그 시간을 덮은 클립의 분류로 요청을 남겨야 원본 기록이 빠지지 않는다.
    private var mergedAwayParents: Set<NLEClipParent> = []

    init(
        clips: [NLEClip],
        rangeStartMinute: Int = 0,
        rangeEndMinute: Int = NLETrack.dayMinutes,
        fillsGaps: Bool = true
    ) {
        let lower = min(rangeStartMinute, rangeEndMinute)
        let upper = max(rangeStartMinute, rangeEndMinute)
        self.rangeStartMinute = lower
        self.rangeEndMinute = max(lower + 1, upper)
        self.fillsGaps = fillsGaps
        self.clips = []
        self.clips = Self.normalized(
            clips,
            rangeStartMinute: self.rangeStartMinute,
            rangeEndMinute: self.rangeEndMinute,
            fillsGaps: fillsGaps
        )
    }

    // MARK: - 읽기

    var isEmpty: Bool { clips.isEmpty }

    var totalLengthMinutes: Int { clips.reduce(0) { $0 + $1.lengthMinutes } }

    func clip(_ id: String) -> NLEClip? {
        clips.first { $0.id == id }
    }

    func clipIndex(_ id: String) -> Int? {
        clips.firstIndex { $0.id == id }
    }

    /// 그 분에 놓인 클립. 경계에 걸치면 시작이 앞선 클립을 고른다.
    func clip(atMinute minute: Int) -> NLEClip? {
        clips.first { $0.contains(minute: minute) }
            ?? clips.last { $0.endMinute == minute }
    }

    /// 선택한 클립 다음/이전 클립. 타임라인을 키보드로 넘길 때 쓴다.
    func neighbor(of id: String, offset: Int) -> NLEClip? {
        guard let index = clipIndex(id) else { return nil }
        let target = index + offset
        guard clips.indices.contains(target) else { return nil }
        return clips[target]
    }

    func clips(inParent parent: NLEClipParent) -> [NLEClip] {
        clips.filter { $0.parent == parent }
    }

    // MARK: - 편집

    /// 시작이나 끝을 민다. 원본 구간을 넘어서면 그 자리에서 멈춘다.
    @discardableResult
    mutating func trim(_ id: String, edge: NLEClipEdge, toMinute: Int) -> Bool {
        guard let index = clipIndex(id) else { return false }
        var clip = clips[index]
        let before = clip
        switch edge {
        case .start:
            let upper = clip.endMinute - Self.minimumClipMinutes
            clip.startMinute = min(max(toMinute, clip.parent.startMinute), upper)
        case .end:
            let lower = clip.startMinute + Self.minimumClipMinutes
            clip.endMinute = max(min(toMinute, clip.parent.endMinute), lower)
        }
        guard clip.startMinute != before.startMinute
            || clip.endMinute != before.endMinute else { return false }
        clips[index] = clip
        renormalize()
        return true
    }

    /// 경계를 맞물려 민다(롤 편집). 한쪽 끝을 밀면 맞닿은 이웃의 반대 끝이 따라 움직인다.
    ///
    /// 동영상 편집기의 롤과 같다. 두 클립 사이에는 빈 시간이 생기지 않고, 클립은
    /// 자기 원본 구간을 넘어설 수 있다. 넘어선 시간은 그 시간을 소유한 원본 구간의
    /// 요청에 조각으로 실리므로 원본 기록의 출처는 그대로 남는다.
    @discardableResult
    mutating func roll(_ id: String, edge: NLEClipEdge, toMinute: Int) -> Bool {
        guard let index = clipIndex(id) else { return false }
        var clip = clips[index]
        switch edge {
        case .start:
            let neighbor = clips.first { $0.id != id && $0.endMinute == clip.startMinute }
            let lower = neighbor.map { $0.startMinute + Self.minimumClipMinutes } ?? rangeStartMinute
            let newStart = min(max(toMinute, lower), clip.endMinute - Self.minimumClipMinutes)
            guard newStart != clip.startMinute else { return false }
            clip.startMinute = newStart
            clips[index] = clip
            if let neighbor, let neighborIndex = clipIndex(neighbor.id) {
                clips[neighborIndex].endMinute = newStart
            }
        case .end:
            let neighbor = clips.first { $0.id != id && $0.startMinute == clip.endMinute }
            let upper = neighbor.map { $0.endMinute - Self.minimumClipMinutes } ?? rangeEndMinute
            let newEnd = max(min(toMinute, upper), clip.startMinute + Self.minimumClipMinutes)
            guard newEnd != clip.endMinute else { return false }
            clip.endMinute = newEnd
            clips[index] = clip
            if let neighbor, let neighborIndex = clipIndex(neighbor.id) {
                clips[neighborIndex].startMinute = newEnd
            }
        }
        renormalize()
        return true
    }

    /// 손잡이 쪽에 맞닿은 이웃 클립.
    func adjacentClip(of id: String, edge: NLEClipEdge) -> NLEClip? {
        guard let clip = clip(id) else { return nil }
        switch edge {
        case .start: return clips.first { $0.id != id && $0.endMinute == clip.startMinute }
        case .end: return clips.first { $0.id != id && $0.startMinute == clip.endMinute }
        }
    }

    /// 경계를 끌어 한쪽 클립이 최소 길이까지 눌렸을 때 합칠 쌍. 눌린 쪽이 남은 쪽으로 들어간다.
    ///
    /// 손잡이를 잡은 클립이 어느 쪽인지와 상관없다. 경계 바로 위를 잡으면 위 클립의 끝 손잡이가 잡혀
    /// 끌어 올릴 때 잡은 클립이 스스로 줄어든다. 그때도 줄어든 클립을 이웃에 합칠지 묻는다(UIX1031A18).
    /// 끌기 전부터 최소 길이였던 클립은 이번 손짓으로 눌린 게 아니므로 묻지 않는다.
    func squeezedMergePair(
        of id: String,
        edge: NLEClipEdge,
        clipLengthAtStart: Int,
        neighborLengthAtStart: Int,
        squeezeMinutes: Int = NLETrack.minimumClipMinutes,
        fingerMinute: Int? = nil
    ) -> (survivor: NLEClip, absorbed: NLEClip)? {
        guard let clip = clip(id), let neighbor = adjacentClip(of: id, edge: edge) else { return nil }
        // 처음부터 최소 길이(1분)인 클립은 더 줄어들 수 없다. 손가락이 그 클립을 지나쳐 밀었으면 합칠지 묻는다(UIX1031A22).
        if let fingerMinute {
            let pushedThroughNeighbor = neighborLengthAtStart <= Self.minimumClipMinutes
                && (edge == .start ? fingerMinute <= neighbor.startMinute : fingerMinute >= neighbor.endMinute)
            let pushedThroughClip = clipLengthAtStart <= Self.minimumClipMinutes
                && (edge == .start ? fingerMinute >= clip.endMinute : fingerMinute <= clip.startMinute)
            if pushedThroughNeighbor, !neighbor.isGap, !clip.isGap { return (clip, neighbor) }
            if pushedThroughClip, !neighbor.isGap, !clip.isGap { return (neighbor, clip) }
        }
        // 화면에서 거의 사라질 만큼 눌렸으면 끝까지 간 것으로 본다. 1분까지 밀지 않아도 묻는다.
        // 기준은 화면 두께(squeezeMinutes)와 처음 길이의 4분의 1 중 작은 쪽이다. 하루 전체 배율에서는
        // 화면 두께가 수십 분이라, 그보다 짧은 클립이 대상에서 빠지거나 조금만 끌어도 묻지 않게 한다(UIX1031A20).
        func squeezed(_ length: Int, from startLength: Int) -> Bool {
            guard startLength > Self.minimumClipMinutes, length < startLength else { return false }
            let limit = max(Self.minimumClipMinutes, min(squeezeMinutes, startLength / 4))
            return length <= limit
        }
        let pair: (survivor: NLEClip, absorbed: NLEClip)
        if squeezed(neighbor.lengthMinutes, from: neighborLengthAtStart) {
            pair = (clip, neighbor)
        } else if squeezed(clip.lengthMinutes, from: clipLengthAtStart) {
            pair = (neighbor, clip)
        } else {
            return nil
        }
        // 기록 없는 미확인 자리는 합칠 대상이 아니다. 아직 원본 ID가 없는 진행 중 구간(아래쪽 마지막 클립)은 합칠 수 있다(UIX1031A19).
        // 같은 분류·이름이어도 두 덩어리로 나뉘어 있으면 하나로 합칠 수 있다(UIX1031A21).
        guard !pair.survivor.isGap, !pair.absorbed.isGap else { return nil }
        return pair
    }

    /// 합치기: 남는 클립이 이웃 자리까지 늘어나 한 덩어리가 되고 이웃 클립은 사라진다.
    /// 넘어선 시간은 그 시간을 소유한 원본 구간의 요청에 조각으로 실리므로 이웃의 원본 기록은 빠지지 않는다.
    @discardableResult
    mutating func mergeIntoDragged(_ id: String, neighborID: String) -> Bool {
        guard let index = clipIndex(id), let neighbor = clip(neighborID),
              clips[index].endMinute == neighbor.startMinute || clips[index].startMinute == neighbor.endMinute
        else { return false }
        clips[index].startMinute = min(clips[index].startMinute, neighbor.startMinute)
        clips[index].endMinute = max(clips[index].endMinute, neighbor.endMinute)
        clips.removeAll { $0.id == neighborID }
        renormalize()
        if !clips.contains(where: { $0.parent == neighbor.parent }) {
            mergedAwayParents.insert(neighbor.parent)
        }
        return true
    }

    /// 길이를 유지한 채 통째로 옮긴다. 원본 구간 안에서만 움직인다.
    /// 옮겨 간 자리에 다른 클립이 있으면 그 클립이 밀려나고, 완전히 덮이면 사라진다.
    @discardableResult
    mutating func move(_ id: String, toStartMinute: Int) -> Bool {
        guard let index = clipIndex(id) else { return false }
        var clip = clips[index]
        let length = clip.lengthMinutes
        let upper = clip.parent.endMinute - length
        let start = min(max(toStartMinute, clip.parent.startMinute), max(clip.parent.startMinute, upper))
        guard start != clip.startMinute else { return false }
        let target = start..<(start + length)

        // 같은 원본 구간 안의 이웃은 옮겨 간 클립에 자리를 내준다.
        for other in clips where other.parent == clip.parent && other.id != clip.id {
            guard other.startMinute < target.upperBound,
                  other.endMinute > target.lowerBound else { continue }
            if other.startMinute >= target.lowerBound,
               other.endMinute <= target.upperBound {
                clips.removeAll { $0.id == other.id }
            } else if other.startMinute < target.lowerBound {
                if let otherIndex = clipIndex(other.id) {
                    clips[otherIndex].endMinute = target.lowerBound
                }
            } else if let otherIndex = clipIndex(other.id) {
                clips[otherIndex].startMinute = target.upperBound
            }
        }

        guard let movedIndex = clipIndex(id) else { return false }
        clip.startMinute = start
        clip.endMinute = start + length
        clips[movedIndex] = clip
        renormalize()
        return true
    }

    /// 재단기(razor). 그 분에서 클립을 둘로 가른다. 뒤 조각은 원본을 함께 물려받는다.
    @discardableResult
    mutating func split(_ id: String, atMinute minute: Int) -> String? {
        guard let index = clipIndex(id) else { return nil }
        let clip = clips[index]
        guard minute > clip.startMinute, minute < clip.endMinute else { return nil }
        let tailID = "\(clip.id)/\(minute)"
        // 두 조각의 기준점을 각자의 새 구간으로 옮긴다. 같은 분류로 가르기만 한
        // 상태는 저장할 것이 없고, 한쪽 분류를 바꿔야 요청이 나간다.
        let head = NLEClip(
            id: clip.id,
            option: clip.option,
            startMinute: clip.startMinute,
            endMinute: minute,
            parent: clip.parent,
            origin: NLEClipOrigin(
                startMinute: clip.startMinute,
                endMinute: minute,
                option: clip.option
            )
        )
        let tail = NLEClip(
            id: tailID,
            option: clip.option,
            startMinute: minute,
            endMinute: clip.endMinute,
            parent: clip.parent,
            origin: NLEClipOrigin(
                startMinute: minute,
                endMinute: clip.endMinute,
                option: clip.option
            )
        )
        clips[index] = head
        clips.insert(tail, at: index + 1)
        renormalize()
        return tailID
    }

    /// 클립을 지운다. 그 자리는 `fallback`으로 돌아간다(대분류는 미확인, 서브클립은 상위 분류).
    @discardableResult
    mutating func delete(_ id: String, fallback: ActivityCorrectionOption? = nil) -> Bool {
        guard let index = clipIndex(id) else { return false }
        if let fallback {
            clips[index].option = fallback
            renormalize()
            return true
        }
        clips.remove(at: index)
        renormalize()
        return true
    }

    @discardableResult
    mutating func setOption(_ id: String, to option: ActivityCorrectionOption) -> Bool {
        guard let index = clipIndex(id), clips[index].option != option else { return false }
        clips[index].option = option
        renormalize()
        return true
    }

    /// 이 클립을 지웠을 때 그 자리를 무엇이 이어받는지 바꾼다.
    ///
    /// 상세활동을 저장할 때, 비운 자리는 그 시각의 대분류가 이어받아야 한다.
    /// 대분류를 먼저 고쳤다면 그 최신 분류가 기준이 된다.
    @discardableResult
    mutating func setFillOption(_ option: ActivityCorrectionOption, forClipID id: String) -> Bool {
        guard let index = clipIndex(id),
              clips[index].parent.fillOption != option else { return false }
        let clip = clips[index]
        clips[index] = NLEClip(
            id: clip.id,
            option: clip.option,
            startMinute: clip.startMinute,
            endMinute: clip.endMinute,
            parent: NLEClipParent(
                startMinute: clip.parent.startMinute,
                endMinute: clip.parent.endMinute,
                sourceIDs: clip.parent.sourceIDs,
                option: clip.parent.option,
                fillOption: option
            ),
            origin: clip.origin
        )
        return true
    }

    /// 구간 하나를 클립 하나로 갈아 끼운다. 그 구간에 걸친 클립은 잘리거나 사라진다.
    ///
    /// 새 클립의 기준점은 그 구간의 원래 분류다. 그래서 센서 결과로 되돌리면
    /// 저장할 것이 없는 상태가 되고, 상세활동을 대분류로 올리면 바뀐 것으로 남는다.
    @discardableResult
    mutating func replace(
        _ range: Range<Int>,
        with option: ActivityCorrectionOption,
        parent: NLEClipParent
    ) -> Bool {
        let lower = max(range.lowerBound, parent.startMinute)
        let upper = min(range.upperBound, parent.endMinute)
        guard lower < upper else { return false }

        var next: [NLEClip] = []
        for clip in clips {
            if clip.endMinute <= lower || clip.startMinute >= upper {
                next.append(clip)
                continue
            }
            // 구간 밖으로 남는 조각은 잘라서 남긴다.
            if clip.startMinute < lower {
                next.append(Self.piece(clip, from: clip.startMinute, to: lower))
            }
            if clip.endMinute > upper {
                next.append(Self.piece(clip, from: upper, to: clip.endMinute))
            }
        }
        next.append(
            NLEClip(
                id: "main|\(lower)-\(upper)|\(option.categoryID)",
                option: option,
                startMinute: lower,
                endMinute: upper,
                parent: parent,
                origin: NLEClipOrigin(
                    startMinute: lower,
                    endMinute: upper,
                    option: parent.option
                )
            )
        )
        clips = next.sorted { lhs, rhs in
            lhs.startMinute == rhs.startMinute
                ? lhs.id < rhs.id
                : lhs.startMinute < rhs.startMinute
        }
        renormalize()
        return true
    }

    /// 잘린 조각은 같은 클립의 성격을 물려받되 이름만 새로 얻는다.
    private static func piece(_ clip: NLEClip, from start: Int, to end: Int) -> NLEClip {
        NLEClip(
            id: "\(clip.id)#\(start)",
            option: clip.option,
            startMinute: start,
            endMinute: end,
            parent: clip.parent,
            origin: clip.origin
        )
    }

    /// 같은 분류끼리 맞닿은 클립을 하나로 합친다. 손으로 가른 흔적을 지울 때 쓴다.
    @discardableResult
    mutating func merge(_ id: String, with neighborID: String) -> Bool {
        guard let index = clipIndex(id),
              let otherIndex = clipIndex(neighborID) else { return false }
        let first = min(index, otherIndex)
        let second = max(index, otherIndex)
        guard let union = Self.merged(clips[first], clips[second]) else { return false }
        clips[first] = union
        clips.remove(at: second)
        renormalize()
        return true
    }

    /// 여러 클립을 한 번에 같은 분류로 덮는다.
    ///
    /// 대표 요청(2026-10-26): BOKKI STUDIO의 자막 합치기처럼, 여러 개로 나뉜 클립을
    /// 하나씩 고치지 않고 한 번에 바꾼다. `matchingCategoryID`를 주면 그 분류의
    /// 클립만 바꾼다(같은 것끼리 모아 바꾸기).
    ///
    /// 원본 기록이 없는 빈 시간(`parent.sourceIDs`가 빈 날 구멍)은 건드리지 않는다.
    /// 센서에 없는 시간을 지어내지 않는다는 이 트랙의 규칙과 같은 이유다.
    @discardableResult
    mutating func overwrite(
        with option: ActivityCorrectionOption,
        matchingCategoryID: String? = nil
    ) -> Int {
        var changed = 0
        for index in clips.indices {
            guard !clips[index].parent.sourceIDs.isEmpty,
                  clips[index].option != option,
                  matchingCategoryID == nil
                    || clips[index].option.categoryID == matchingCategoryID else { continue }
            clips[index].option = option
            changed += 1
        }
        guard changed > 0 else { return 0 }
        renormalize()
        return changed
    }

    /// 맞닿은 같은 분류·같은 원본 구간 클립을 모두 하나로 합친다.
    ///
    /// 손으로 가른 클립을 되돌리는 일이다(자막 합치기와 같다). 덮기와 함께 쓰면
    /// 같은 분류가 된 이웃이 하나로 붙어, 하루가 원본 구간 수만큼의 띠로 정리된다.
    @discardableResult
    mutating func mergeAdjacent() -> Int {
        var merged = 0
        var result: [NLEClip] = []
        for clip in clips.sorted(by: { lhs, rhs in
            lhs.startMinute == rhs.startMinute
                ? lhs.id < rhs.id
                : lhs.startMinute < rhs.startMinute
        }) {
            if let last = result.last, let union = Self.merged(last, clip) {
                result[result.count - 1] = union
                merged += 1
                continue
            }
            result.append(clip)
        }
        guard merged > 0 else { return 0 }
        clips = result
        renormalize()
        return merged
    }

    /// 두 클립을 하나로 합칠 수 있으면 합친 클립을 돌려준다.
    ///
    /// 기준점(`origin`)이 이어져 있으면(가르기만 한 상태) 합친 구간으로 넓힌다.
    /// 그래야 가르기→합치기가 '저장할 것이 없는' 왕복이 되고, 한쪽이라도 분류를
    /// 바꿨으면 합친 구간 전체가 바뀐 것으로 남는다.
    private static func merged(_ a: NLEClip, _ b: NLEClip) -> NLEClip? {
        guard a.endMinute == b.startMinute,
              a.parent == b.parent,
              a.option == b.option else { return nil }
        let origin = NLEClipOrigin(
            startMinute: a.origin.startMinute,
            endMinute: a.origin.endMinute == b.origin.startMinute
                ? b.origin.endMinute
                : a.origin.endMinute,
            option: a.origin.option
        )
        return NLEClip(
            id: a.id,
            option: a.option,
            startMinute: a.startMinute,
            endMinute: b.endMinute,
            parent: a.parent,
            origin: origin
        )
    }

    /// 되돌리기용 스냅숏. 클립 배열이 값 타입이라 통째로 담아 두면 된다.
    func snapshot() -> [NLEClip] { clips }

    mutating func restore(_ snapshot: [NLEClip]) {
        clips = Self.normalized(
            snapshot,
            rangeStartMinute: rangeStartMinute,
            rangeEndMinute: rangeEndMinute,
            fillsGaps: fillsGaps
        )
    }

    // MARK: - 커밋

    /// 바뀐 클립을 원본 구간별 `cover` 요청으로 묶는다.
    /// 원본 구간 하나에 요청 하나이므로, 한 구간 안에서 여러 번 잘라도 결과가 겹치지 않는다.
    func editRequests(
        dayStart: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> [ActivitySectionEditRequest] {
        let dirty = clips.filter(\.isDirty)
        guard !dirty.isEmpty else { return [] }
        // 롤로 원본 구간을 넘어선 클립은 그 시간을 소유한 이웃 구간에도 조각을 남긴다.
        var touched = Set(dirty.map(\.parent))
        for clip in dirty {
            for parent in Set(clips.map(\.parent)).union(mergedAwayParents) where parent.startMinute < clip.endMinute
                && parent.endMinute > clip.startMinute {
                touched.insert(parent)
            }
        }
        return touched
            .sorted { $0.startMinute < $1.startMinute }
            .compactMap { parent in
                // 이 구간의 요청은 이 구간의 시간만 덮는다. 넘어온 조각은 여기서 잘린다.
                let pieces = clips
                    .filter { $0.startMinute < parent.endMinute && $0.endMinute > parent.startMinute }
                    .sorted { $0.startMinute < $1.startMinute }
                    .compactMap { clip -> ActivitySectionOverridePiece? in
                        let lower = max(clip.startMinute, parent.startMinute)
                        let upper = min(clip.endMinute, parent.endMinute)
                        guard let start = calendar.date(
                            byAdding: .minute,
                            value: lower,
                            to: dayStart
                        ), let end = calendar.date(
                            byAdding: .minute,
                            value: upper,
                            to: dayStart
                        ), start < end else { return nil }
                        return ActivitySectionOverridePiece(
                            span: TimeSpan(start: start, end: end),
                            option: clip.option
                        )
                    }
                guard !pieces.isEmpty,
                      let originalStart = calendar.date(
                          byAdding: .minute,
                          value: parent.startMinute,
                          to: dayStart
                      ), let originalEnd = calendar.date(
                          byAdding: .minute,
                          value: parent.endMinute,
                          to: dayStart
                      ) else { return nil }
                return ActivitySectionEditRequest(
                    sourceIDs: parent.sourceIDs,
                    originalSpan: TimeSpan(start: originalStart, end: originalEnd),
                    originalOption: parent.option,
                    mode: .cover(pieces: pieces, fill: parent.fillOption)
                )
            }
    }

    // MARK: - 정규화

    private mutating func renormalize() {
        clips = Self.normalized(
            clips,
            rangeStartMinute: rangeStartMinute,
            rangeEndMinute: rangeEndMinute,
            fillsGaps: fillsGaps
        )
    }

    private static func normalized(
        _ input: [NLEClip],
        rangeStartMinute: Int,
        rangeEndMinute: Int,
        fillsGaps: Bool
    ) -> [NLEClip] {
        // 클립은 자기 원본 구간을 넘어설 수 있다(경계를 맞물려 미는 롤 편집).
        // 대신 서로 겹치지 않게 정리하고, 비어 있는 시간은 그 시간을 소유한 원본 구간의
        // 미확인으로 채운다. 그래야 넘어선 클립이 이웃 구간에 구멍을 내지 않는다.
        var ordered: [NLEClip] = []
        var parents: Set<NLEClipParent> = []
        var cursor = rangeStartMinute
        for var clip in input.sorted(by: { lhs, rhs in
            if lhs.startMinute != rhs.startMinute {
                return lhs.startMinute < rhs.startMinute
            }
            return lhs.id < rhs.id
        }) {
            clip.startMinute = max(clip.startMinute, rangeStartMinute)
            clip.endMinute = min(clip.endMinute, rangeEndMinute)
            guard clip.startMinute < clip.endMinute else { continue }
            if clip.startMinute < cursor {
                clip.startMinute = cursor
            }
            guard clip.startMinute < clip.endMinute else { continue }
            parents.insert(clip.parent)
            ordered.append(clip)
            cursor = clip.endMinute
        }

        var result: [NLEClip] = []
        if fillsGaps {
            for parent in parents {
                for gap in uncovered(parent: parent, coveredBy: ordered) {
                    result.append(gapClip(parent: parent, from: gap.lowerBound, to: gap.upperBound))
                }
            }
        }
        result.append(contentsOf: ordered)

        // 원본 구간이 비어 있는 날(아직 아무 기록도 없는 날)도 하루를 채운다.
        if fillsGaps {
            result = fillUncoveredDay(
                result,
                rangeStartMinute: rangeStartMinute,
                rangeEndMinute: rangeEndMinute
            )
        }
        result = mergingAdjacentGaps(result)
        return result.sorted { lhs, rhs in
            if lhs.startMinute != rhs.startMinute {
                return lhs.startMinute < rhs.startMinute
            }
            return lhs.id < rhs.id
        }
    }

    /// 그 원본 구간 안에서 아무 클립도 덮지 않은 자리.
    ///
    /// 클립이 원본 구간을 넘어설 수 있게 되면서, 빈자리는 구간 하나만 보고 판단할 수
    /// 없어졌다. 이웃 구간에서 넘어온 클립까지 함께 보고 남은 자리만 돌려준다.
    private static func uncovered(
        parent: NLEClipParent,
        coveredBy clips: [NLEClip]
    ) -> [Range<Int>] {
        var gaps: [Range<Int>] = []
        var cursor = parent.startMinute
        for clip in clips where clip.endMinute > parent.startMinute
            && clip.startMinute < parent.endMinute {
            let start = max(clip.startMinute, parent.startMinute)
            let end = min(clip.endMinute, parent.endMinute)
            if start > cursor {
                gaps.append(cursor..<start)
            }
            cursor = max(cursor, end)
        }
        if cursor < parent.endMinute {
            gaps.append(cursor..<parent.endMinute)
        }
        return gaps
    }

    /// 같은 원본 구간 안에서 맞닿은 미확인 조각을 하나로 합친다.
    ///
    /// 클립 끝을 조금씩 여러 번 당기면 당길 때마다 비운 자리가 새 미확인 클립으로
    /// 쌓여, 타임라인에 '미확인' 상자가 여러 개 늘어섰다(대표 지적, UXP1024D20 ④).
    /// 미확인은 사람이 일부러 가르는 분류가 아니므로 곧바로 합쳐 하나만 남긴다.
    private static func mergingAdjacentGaps(_ clips: [NLEClip]) -> [NLEClip] {
        var merged: [NLEClip] = []
        for clip in clips.sorted(by: { lhs, rhs in
            if lhs.startMinute != rhs.startMinute {
                return lhs.startMinute < rhs.startMinute
            }
            return lhs.id < rhs.id
        }) {
            if var last = merged.last,
               last.isGap,
               clip.isGap,
               last.parent == clip.parent,
               last.endMinute == clip.startMinute {
                last.endMinute = clip.endMinute
                merged[merged.count - 1] = last
                continue
            }
            merged.append(clip)
        }
        return merged
    }

    private static func fillUncoveredDay(
        _ clips: [NLEClip],
        rangeStartMinute: Int,
        rangeEndMinute: Int
    ) -> [NLEClip] {
        var result: [NLEClip] = []
        var cursor = rangeStartMinute
        for clip in clips.sorted(by: { $0.startMinute < $1.startMinute }) {
            if clip.startMinute > cursor {
                result.append(dayGapClip(from: cursor, to: clip.startMinute))
            }
            if clip.endMinute > cursor {
                result.append(clip)
                cursor = clip.endMinute
            }
        }
        if cursor < rangeEndMinute {
            result.append(dayGapClip(from: cursor, to: rangeEndMinute))
        }
        return result
    }

    private static func dayGapClip(from start: Int, to end: Int) -> NLEClip {
        let option = ActivitySectionOverrideEngine.unconfirmedOption
        let parent = NLEClipParent(
            startMinute: start,
            endMinute: end,
            sourceIDs: [],
            option: option,
            fillOption: option
        )
        return NLEClip(
            id: "day-gap|\(start)-\(end)",
            option: option,
            startMinute: start,
            endMinute: end,
            parent: parent,
            origin: NLEClipOrigin(startMinute: start, endMinute: end, option: option)
        )
    }

    private static func gapClip(
        parent: NLEClipParent,
        from start: Int,
        to end: Int
    ) -> NLEClip {
        let option = ActivitySectionOverrideEngine.unconfirmedOption
        return NLEClip(
            id: "gap|\(parent.stableKey)|\(start)-\(end)",
            option: option,
            startMinute: start,
            endMinute: end,
            parent: parent,
            origin: NLEClipOrigin(startMinute: start, endMinute: end, option: option)
        )
    }
}

/// 자석처럼 붙는 지점. 동영상 편집기의 스냅과 같은 규칙을 쓴다.
enum NLESnapPolicy {
    static let thresholdMinutes = 3

    static func snapped(
        _ minute: Int,
        to targets: [Int],
        threshold: Int = thresholdMinutes
    ) -> Int {
        var best = minute
        var bestDistance = threshold + 1
        for target in targets {
            let distance = abs(target - minute)
            if distance <= threshold, distance < bestDistance {
                best = target
                bestDistance = distance
            }
        }
        return best
    }

    /// 다른 클립의 양 끝, 재생 헤드, 하루의 양 끝.
    static func targets(
        for track: NLETrack,
        excluding clipID: String? = nil,
        playheadMinute: Int? = nil
    ) -> [Int] {
        var values: Set<Int> = [track.rangeStartMinute, track.rangeEndMinute]
        for clip in track.clips where clip.id != clipID {
            values.insert(clip.startMinute)
            values.insert(clip.endMinute)
        }
        if let playheadMinute {
            values.insert(min(max(playheadMinute, track.rangeStartMinute), track.rangeEndMinute))
        }
        return values.sorted()
    }
}

/// 길게 눌러 집어 들기와 가장자리 자동 스크롤의 손가락 계약.
///
/// 동영상 편집기(BOKKI STUDIO)의 값을 그대로 쓴다. 0.4초를 누르고 있으면 클립을
/// 집어 들고, 그 전에 18pt 넘게 움직이면 집어 들지 않고 화면을 흐르게 한다.
/// 가장자리에서는 시간에 비례해 360pt/s로 흐르므로 프레임 간격이 달라도 속도가 같다.
enum NLEReorderHoldPolicy {
    static let delay: TimeInterval = 0.4
    static let tolerance: CGFloat = 18
    static let pointsPerSecond: CGFloat = 360
    /// 한 번에 반영하는 최대 경과(초). 멈췄다 돌아와도 화면이 튀지 않는다.
    static let maximumStep: TimeInterval = 0.1

    /// 집어 들 때인가. 누른 지 오래되고 손가락이 거의 안 움직였을 때만 참이다.
    static func shouldLift(after elapsed: TimeInterval, distance: CGFloat) -> Bool {
        elapsed >= delay && distance <= tolerance
    }

    /// 가장자리에서 흐를 거리(pt). 경과 시간에 비례한다.
    static func scrollPoints(elapsed: TimeInterval) -> CGFloat {
        pointsPerSecond * CGFloat(min(max(elapsed, 0), maximumStep))
    }
}

/// 타임라인 좌표 ↔ 분 변환. 확대·스크롤은 여기 한 곳에서만 계산한다.
struct NLETimelineGeometry: Hashable, Sendable {
    var minuteWidth: CGFloat
    var visibleStartMinute: Double
    var visibleMinutes: Double

    static let fullDay = NLETimelineGeometry(
        minuteWidth: 1,
        visibleStartMinute: 0,
        visibleMinutes: 1_440
    )

    func x(forMinute minute: Double) -> CGFloat {
        CGFloat((minute - visibleStartMinute) * Double(minuteWidth))
    }

    func minute(forX x: CGFloat) -> Double {
        visibleStartMinute + Double(x) / Double(max(0.000_1, minuteWidth))
    }

    func width(minutes: Double) -> CGFloat {
        CGFloat(max(0, minutes) * Double(minuteWidth))
    }

    // 하루는 세로로 흐른다. 같은 계산을 y축 이름으로도 쓴다.

    func y(forMinute minute: Double) -> CGFloat {
        x(forMinute: minute)
    }

    func minute(forY y: CGFloat) -> Double {
        minute(forX: y)
    }

    func height(minutes: Double) -> CGFloat {
        width(minutes: minutes)
    }

    var visibleEndMinute: Double { visibleStartMinute + visibleMinutes }
}
