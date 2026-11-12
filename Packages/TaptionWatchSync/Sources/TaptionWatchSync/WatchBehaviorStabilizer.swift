import Foundation

/// 2.56초 창 판정이 한두 창 튀는 것을 눌러 준다.
///
/// 예전에는 「새 판정의 점수가 지금 점수 + 0.08보다 낮으면 지금 행동 유지」만 있어,
/// 걷기(0.79)가 한 번 나오면 정지(0.55)로는 영영 돌아가지 못했다(WSN1112A01).
/// 이제 같은 새 행동이 연달아 `confirmationWindows`번 나오면 점수와 상관없이 바꾼다.
public struct WatchBehaviorStabilizer: Sendable {
    public static let confirmationWindows = 2
    public static let immediateSwitchMargin = 0.08
    public static let heldEvidence = "시간적 안정화"

    private var currentKind: WatchBehaviorKind?
    private var currentConfidence = 0.0
    private var challenger: WatchBehaviorKind?
    private var challengerCount = 0

    public init() {}

    public mutating func reset() {
        self = WatchBehaviorStabilizer()
    }

    public mutating func stabilize(
        _ inference: WatchBehaviorInference
    ) -> WatchBehaviorInference {
        guard let currentKind, currentKind != inference.kind else {
            accept(inference)
            return inference
        }
        if challenger == inference.kind {
            challengerCount += 1
        } else {
            challenger = inference.kind
            challengerCount = 1
        }
        if inference.confidenceScore >= currentConfidence + Self.immediateSwitchMargin
            || challengerCount >= Self.confirmationWindows {
            accept(inference)
            return inference
        }
        return WatchBehaviorInference(
            kind: currentKind,
            confidenceScore: currentConfidence,
            // 밀려난 판정의 근거를 섞으면 「저진동」과 「달리기 범위」가 한 기록에 함께 남는다.
            evidence: [Self.heldEvidence],
            modelVersion: inference.modelVersion
        )
    }

    private mutating func accept(_ inference: WatchBehaviorInference) {
        currentKind = inference.kind
        currentConfidence = inference.confidenceScore
        challenger = nil
        challengerCount = 0
    }
}
