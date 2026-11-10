import Foundation

/// 창이 화면에 넘기는 요청. 분류가 없으면 합치기만 한다.
struct NLEOverwriteRequest: Equatable {
    let category: MapHomeSidebarMajorCategory?
    let scope: NLEOverwriteScope
    let mergesAfter: Bool
    /// 범위 안 상세활동도 지우고 새 분류로 채울지. 기본은 남긴다(대표 결정, 2026-11-08).
    var clearsDetails = false
    /// 직접 입력한 기록이 든 클립도 덮을지. 끄면 그 클립은 그대로 남는다.
    var includesUserOwned = true
}

/// 덮기·합치기 계산. 창이 보여 주는 수와 화면이 실제로 바꾸는 수가 같도록 한 곳에 모은다.
enum NLEOverwritePolicy {
    struct Result: Equatable {
        var track: NLETrack
        var changed: Int
        var merged: Int
        /// 상세활동 줄. 상세활동을 지우지 않으면 넘긴 그대로다.
        var subTrack: NLETrack? = nil
        /// 직접 입력이라 건너뛴 클립 수.
        var skipped = 0
        /// 지운 상세활동 수.
        var removedDetails = 0
    }

    static let sleepCategoryID = "sleep"

    /// 덮으면 바뀌는 클립 수. 미확인도 센다(원본 없이 채운 분류는 세지 않는다).
    static func affectedCount(
        _ track: NLETrack,
        scope: NLEOverwriteScope,
        selectedCategoryID: String?,
        pickedClipIDs: Set<String> = []
    ) -> Int {
        track.clips.filter { includes($0, scope: scope, selectedCategoryID: selectedCategoryID, pickedClipIDs: pickedClipIDs) }.count
    }

    static func includes(_ clip: NLEClip, scope: NLEOverwriteScope, selectedCategoryID: String?, pickedClipIDs: Set<String>) -> Bool {
        guard clip.isOverwritable else { return false }
        return switch scope {
        case .wholeDay: true
        case .sameCategory: clip.option.categoryID == selectedCategoryID
        case .picked: pickedClipIDs.contains(clip.id)
        }
    }

    /// 이 분류로 덮을 때 실제로 바뀌는 클립. `NLETrack.overwrite`와 같은 조건이다.
    static func targets(
        _ track: NLETrack,
        option: ActivityCorrectionOption,
        scope: NLEOverwriteScope,
        selectedCategoryID: String?,
        pickedClipIDs: Set<String> = []
    ) -> [NLEClip] {
        guard scope != .sameCategory || selectedCategoryID != nil else { return [] }
        return track.clips.filter { clip in
            clip.option != option && includes(clip, scope: scope, selectedCategoryID: selectedCategoryID, pickedClipIDs: pickedClipIDs)
        }
    }

    /// 직접 입력한 기록을 품은 원본 구간. 한 구간의 클립은 같은 기록을 나눠 가지므로 구간째로 건너뛴다.
    static func userOwnedParents(
        _ clips: [NLEClip],
        userOwnedSourceIDs: Set<UUID>
    ) -> Set<NLEClipParent> {
        guard !userOwnedSourceIDs.isEmpty else { return [] }
        return Set(clips.map(\.parent).filter {
            !userOwnedSourceIDs.isDisjoint(with: $0.sourceIDs)
        })
    }

    /// 수면이 사라지거나 새로 생기는 분(분 단위 합).
    static func sleepMinutesChanged(_ clips: [NLEClip], to option: ActivityCorrectionOption) -> Int {
        let becomesSleep = option.categoryID == sleepCategoryID
        return clips
            .filter { ($0.option.categoryID == sleepCategoryID) != becomesSleep }
            .reduce(0) { $0 + $1.lengthMinutes }
    }

    /// 「수면 N시간이 바뀝니다」. 시간은 소수 첫째 자리까지 쓴다(90분 → 1.5시간).
    static func sleepChangeText(minutes: Int, language: MapHomeLanguage) -> String? {
        guard minutes > 0 else { return nil }
        let hours = String(format: "%.1f", Double(minutes) / 60)
        return language.text(
            "수면 \(hours)시간이 바뀝니다",
            "\(hours) h of sleep will change"
        )
    }

    /// 지금 맞닿은 같은 분류를 합치면 줄어드는 클립 수.
    static func mergeableCount(_ track: NLETrack) -> Int {
        var copy = track
        return copy.mergeAdjacent()
    }

    /// 범위 안 상세활동을 지우고 `fill`로 채운다. 범위에 걸친 상세활동은 경계에서 갈라 안쪽만 지운다.
    @discardableResult
    static func clearDetails(
        _ subTrack: inout NLETrack,
        inside ranges: [Range<Int>],
        fill: ActivityCorrectionOption
    ) -> Int {
        var removed = 0
        for range in coalesced(ranges) {
            for clip in subTrack.clips where clip.startMinute < range.upperBound
                && clip.endMinute > range.lowerBound && clip.option != fill {
                var id = clip.id
                if clip.startMinute < range.lowerBound,
                   let tail = subTrack.split(id, atMinute: range.lowerBound) {
                    id = tail
                }
                if let current = subTrack.clip(id), current.endMinute > range.upperBound {
                    _ = subTrack.split(id, atMinute: range.upperBound)
                }
                if subTrack.delete(id, fallback: fill) { removed += 1 }
            }
        }
        return removed
    }

    /// 지울 상세활동 수. 창이 누르기 전에 보여 준다.
    static func detailCount(
        _ subTrack: NLETrack,
        inside clips: [NLEClip],
        fill: ActivityCorrectionOption
    ) -> Int {
        var copy = subTrack
        return clearDetails(&copy, inside: clips.map { $0.startMinute..<$0.endMinute }, fill: fill)
    }

    static func apply(
        _ track: NLETrack,
        subTrack: NLETrack? = nil,
        option: ActivityCorrectionOption?,
        scope: NLEOverwriteScope,
        selectedCategoryID: String?,
        mergesAfter: Bool,
        userOwnedSourceIDs: Set<UUID> = [],
        includesUserOwned: Bool = true,
        clearsDetails: Bool = false,
        pickedClipIDs: Set<String> = []
    ) -> Result {
        var next = track
        var result = Result(track: track, changed: 0, merged: 0, subTrack: subTrack)
        var skippedParents: Set<NLEClipParent> = []
        if let option {
            let candidates = targets(track, option: option, scope: scope, selectedCategoryID: selectedCategoryID, pickedClipIDs: pickedClipIDs)
            if !includesUserOwned {
                skippedParents = userOwnedParents(candidates, userOwnedSourceIDs: userOwnedSourceIDs)
            }
            let changing = candidates.filter { !skippedParents.contains($0.parent) }
            result.skipped = candidates.count - changing.count
            if !changing.isEmpty {
                result.changed = next.overwrite(
                    with: option,
                    matchingCategoryID: scope == .sameCategory ? selectedCategoryID : nil,
                    skippingParents: skippedParents,
                    onlyClipIDs: scope == .picked ? pickedClipIDs : nil
                )
            }
            if clearsDetails, var detail = subTrack {
                result.removedDetails = clearDetails(
                    &detail,
                    inside: changing.map { $0.startMinute..<$0.endMinute },
                    fill: option
                )
                result.subTrack = detail
            }
        }
        // 분류를 고르지 않았으면 합치기만 하는 요청이다. 건너뛴 직접 입력 구간은 합치지도 않는다.
        result.merged = mergesAfter || option == nil ? next.mergeAdjacent(skippingParents: skippedParents) : 0
        result.track = next
        return result
    }

    private static func coalesced(_ ranges: [Range<Int>]) -> [Range<Int>] {
        ranges.sorted { $0.lowerBound < $1.lowerBound }.reduce(into: []) { result, range in
            if let last = result.last, range.lowerBound <= last.upperBound {
                result[result.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                result.append(range)
            }
        }
    }
}
