import Foundation
import TaptionPlanEngine

/// 신호 대기·엘리베이터처럼 짧게 멈춰 쪼개진 같은 이동을 하나로 잇는 규칙 (CLN1110A01).
enum MovementFragmentMerge {
    /// 3분: 신호 한 주기(보통 2~3분)와 엘리베이터 대기를 덮고, 머문 곳으로 치는 5분보다 짧다.
    static let maximumPause: TimeInterval = 3 * 60
    /// 3분: 다른 발 이동(걷기↔달리기)에 흡수해도 되는 조각 길이. 이보다 길면 따로 한 이동이다.
    static let maximumFragment: TimeInterval = 3 * 60

    /// 이을 조각의 인덱스 묶음. `key`가 같은 이동끼리, 사이 틈(짧은 정지 포함)이 3분 미만일 때만 잇는다.
    /// 뒤따르는 잠긴 조각(사용자 수정·숨김)과 막힌 틈(긴 체류·등록 장소)은 넘지 않는다.
    /// 머리 조각이 잠긴 것은 합친 기록 자체를 고친 것이라, 그대로 이어 수정이 합친 기록에 붙는다 (REV1110A06).
    static func chains(
        spans: [TimeSpan],
        key: (Int) -> String?,
        isPause: (Int) -> Bool,
        isLocked: (Int) -> Bool,
        isBlocked: (TimeSpan) -> Bool
    ) -> [Range<Int>] {
        var result: [Range<Int>] = []
        var head = 0
        while head < spans.count {
            var end = head + 1
            if let mode = key(head) {
                var chainEnd = spans[head].end
                while end < spans.count {
                    let next = isPause(end) ? end + 1 : end
                    guard next < spans.count, key(next) == mode,
                          !isLocked(end), !isLocked(next) else { break }
                    let gap = TimeSpan(start: chainEnd, end: max(chainEnd, spans[next].start))
                    guard gap.duration < maximumPause, !isBlocked(gap) else { break }
                    chainEnd = max(chainEnd, spans[next].end)
                    end = next + 1
                }
            }
            result.append(head..<end)
            head = end
        }
        return result
    }

    /// 걷기·달리기는 같은 발 이동이라 짧은 틈이면 함께 잇는다. 그 밖의 수단은 같아야 잇는다.
    static func compatible(_ lhs: TravelMode, _ rhs: TravelMode) -> Bool {
        lhs == rhs || (isOnFoot(lhs) && isOnFoot(rhs))
    }

    private static func isOnFoot(_ mode: TravelMode) -> Bool { mode == .walking || mode == .running }

    /// 두 이동을 이을 때 남길 수단. 같은 수단은 기존 틈(`maximumGap`)까지, 걷기·달리기처럼 맞는 수단은
    /// 3분 미만 틈에서 짧은 쪽이 3분 미만 조각일 때만 잇고 더 오래 한 쪽 수단을 남긴다. 20분 걷고 30분 달린
    /// 것처럼 둘 다 긴 이동은 따로 둔다 (REV1110A06). 사용자가 확정한 수단끼리는 바꾸지 않는다.
    static func coalescedMode(_ last: TravelSegment, _ next: TravelSegment, maximumGap: TimeInterval) -> TravelMode? {
        let gap = next.span.start.timeIntervalSince(last.span.end)
        if last.mode == next.mode { return gap <= maximumGap ? last.mode : nil }
        guard compatible(last.mode, next.mode), gap < maximumPause,
              min(last.span.duration, next.span.duration) < maximumFragment,
              !last.isConfirmed, !next.isConfirmed else { return nil }
        return next.span.duration > last.span.duration ? next.mode : last.mode
    }

    /// 등록 장소에 머문 자국이 틈에 있으면 짧아도 머문 것이다.
    static func crossesRegisteredStay(_ gap: TimeSpan, stays: [PlaceStay]) -> Bool {
        stays.contains { $0.isRegisteredFrequentPlace && $0.span.intersection(with: gap) != nil }
    }
}

extension MotionActivityActualEngine {
    /// Core Motion 조각을 잇는다. 합친 기록은 첫 조각의 식별자를 쓰고, 흡수한 조각은 근거로 남는다.
    /// 뒤따르는 조각에 붙은 `protectedIDs`(사용자 수정·숨김)는 합치지 않아 그 수정이 사라지지 않는다 (CLN1110A01).
    /// 첫 조각의 식별자는 합친 기록의 식별자라, 숨기거나 고쳐도 합친 채로 남는다 (REV1110A06).
    static func bridgingFragments(
        _ pieces: [MotionActivityRecord],
        protectedIDs: Set<UUID>,
        stays: [TimeSpan]
    ) -> [(activity: MotionActivityRecord, id: UUID, evidence: [String])] {
        let chains = MovementFragmentMerge.chains(
            spans: pieces.map(\.span),
            key: { pieces[$0].motion.isMovement ? pieces[$0].motion.rawValue : nil },
            isPause: { pieces[$0].motion == .stationary && pieces[$0].span.duration < MovementFragmentMerge.maximumPause },
            isLocked: { protectedIDs.contains(stableID(for: pieces[$0])) },
            isBlocked: { gap in stays.contains { $0.intersection(with: gap) != nil } }
        )
        return chains.map { chain in
            var merged = pieces[chain.lowerBound]
            for piece in pieces[chain] where piece.motion == merged.motion {
                merged.span.end = max(merged.span.end, piece.span.end)
                if piece.confidence == .high || (piece.confidence == .medium && merged.confidence == .low) {
                    merged.confidence = piece.confidence
                }
            }
            return (merged, stableID(for: pieces[chain.lowerBound]), mergeEvidence(pieces[chain]))
        }
    }

    /// 흡수한 정지 수만 센다. 정지 없이 틈만 이었으면 끊김을 이었다고 적는다 (REV1110A06).
    private static func mergeEvidence(_ chain: ArraySlice<MotionActivityRecord>) -> [String] {
        let pauses = chain.filter { $0.motion == .stationary }.count
        if pauses > 0 { return ["짧은 멈춤 \(pauses)곳 합침"] }
        return chain.count > 1 ? ["짧은 끊김 이어 붙임"] : []
    }
}
