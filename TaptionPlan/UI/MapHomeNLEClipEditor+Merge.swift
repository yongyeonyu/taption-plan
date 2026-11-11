import SwiftUI

/// 경계 손잡이를 끌어 이웃 클립을 합치는 흐름(RNG1111A02·RNG1111A03).
///
/// 편집기 본문은 줄 예산이 묶여 있어 합치기 판단·확정은 여기 둔다.
extension MapHomeNLEClipEditor {
    func recordTrimNeighborLength(lane: NLEEditorLane, id: String, edge: NLEClipEdge) {
        guard lane == .main, trimLengthsAtStart == nil else { return }
        trimLengthsAtStart = (
            track.clip(id)?.lengthMinutes ?? 0,
            track.adjacentClip(of: id, edge: edge)?.lengthMinutes ?? 0
        )
    }

    func askToMergeIfReachedNeighborEnd() {
        guard let lengths = trimLengthsAtStart else { return }
        let target: (id: String, edge: NLEClipEdge)
        switch dragMode {
        case let .trimStart(.main, id): target = (id, .start)
        case let .trimEnd(.main, id): target = (id, .end)
        default: return
        }
        // 손가락이 이웃 클립의 가운데를 지나갔으면 지나간 것 모두를 끈 클립으로 합칠지 묻는다(RNG1111A02).
        let chain = track.clipsPassed(from: target.id, edge: target.edge, fingerMinute: lastDragMinute)
        if let first = chain.first, let dragged = track.clip(target.id), !dragged.isGap {
            stopAutoScroll()
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            mergePrompt = NLEMergePrompt(
                clipID: dragged.id, neighborID: first.id,
                clipTitle: Self.mainTitle(dragged.option, language: language),
                neighborTitle: Self.mainTitle(first.option, language: language),
                chainIDs: chain.map(\.id)
            )
            return
        }
        // 지금 배율에서 18pt보다 얇게 눌린 클립은 끝까지 민 것으로 본다.
        let squeezeMinutes = Int((Self.mergeSqueezePoints / max(0.01, minuteHeight)).rounded(.up))
        let pair = track.squeezedMergePair(
            of: target.id, edge: target.edge,
            clipLengthAtStart: lengths.clip, neighborLengthAtStart: lengths.neighbor,
            squeezeMinutes: squeezeMinutes,
            fingerMinute: lastDragMinute
        )
        #if DEBUG
        let neighbor = track.adjacentClip(of: target.id, edge: target.edge)
        NSLog("[NLEMerge] edge=%@ clip=%@ %d→%d neighbor=%@ %d→%d squeeze=%d offered=%d",
              target.edge == .end ? "end" : "start",
              track.clip(target.id)?.option.title ?? "-", lengths.clip, track.clip(target.id)?.lengthMinutes ?? -1,
              neighbor?.option.title ?? "-", lengths.neighbor, neighbor?.lengthMinutes ?? -1,
              squeezeMinutes, pair == nil ? 0 : 1)
        #endif
        guard let pair else { return }
        TaptionPlanDiagnosticsLogger.shared.record(
            "nle_merge_offer",
            metrics: [
                "edge_end": target.edge == .end ? 1 : 0,
                "clip_start_len": Double(lengths.clip),
                "neighbor_start_len": Double(lengths.neighbor),
                "clip_len": Double(track.clip(target.id)?.lengthMinutes ?? -1),
                "neighbor_len": Double(track.adjacentClip(of: target.id, edge: target.edge)?.lengthMinutes ?? -1),
                "squeeze_min": Double(squeezeMinutes),
            ]
        )
        // 손을 떼지 않아도 눌리는 순간 묻는다. 화면 흐름은 멈춘다.
        stopAutoScroll()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        mergePrompt = NLEMergePrompt(
            clipID: pair.survivor.id, neighborID: pair.absorbed.id,
            clipTitle: Self.mainTitle(pair.survivor.option, language: language),
            neighborTitle: Self.mainTitle(pair.absorbed.option, language: language)
        )
    }

    func confirmMerge(_ prompt: NLEMergePrompt) {
        guard track.clip(prompt.clipID) != nil else { return }
        pushUndo()
        let neighbors = prompt.chainIDs.isEmpty ? [prompt.neighborID] : prompt.chainIDs
        if track.mergeChain(into: prompt.clipID, neighbors: neighbors) > 0 {
            selectedClipID = prompt.clipID
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
    }
}
