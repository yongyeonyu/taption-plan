import Foundation

/// 평상시(운동 세션 밖) 손목 가속도 한 묶음(보통 10분)을 집 안 활동으로 볼지 정한다.
///
/// 예전 기준(가속도 변동 0.018g 또는 평균 저크 0.018g/s 이상)은 가만히 앉아 있어도 넘어,
/// 집에 있는 내내 「집안일」이 이어졌다(WSN1112A01). 이제 창 판정의 시간 비율과 묶음 전체의
/// 가속도 변동을 함께 보고, 근거에 실제 값을 남긴다.
public struct WatchAmbientChunkVerdict: Hashable, Sendable {
    public enum Outcome: String, Sendable {
        /// 걷기와 손동작이 섞인 움직임. 집이면 집안일 후보.
        case mixedActivity
        /// 거의 움직이지 않음.
        case still
        /// 대부분 걷기·달리기. 이동은 iPhone 쪽 판정이 맡는다.
        case mostlyGait
        /// 판정할 만큼 길지 않거나 표본이 모자람.
        case insufficient
    }

    public var outcome: Outcome
    public var confidenceScore: Double
    /// 창 판정이 덮은 시간 가운데 걷기·달리기·계단 비율.
    public var gaitShare: Double
    /// 손동작(양치·식사·타이핑·불규칙 움직임 등) 비율.
    public var handShare: Double
    public var evidence: [String]
}

public enum WatchAmbientChunkInterpreter {
    public static let minimumDuration: TimeInterval = 20
    public static let minimumSampleCount = 40
    /// 묶음 전체 가속도 크기의 표준편차가 이 값을 넘으면 분명히 움직인 것으로 본다.
    public static let movingStandardDeviationG = 0.04
    public static let minimumActiveShare = 0.25
    public static let maximumGaitShare = 0.7

    public static func interpret(
        duration: TimeInterval,
        sampleCount: Int,
        standardDeviationG: Double?,
        segments: [WatchBehaviorSegment]
    ) -> WatchAmbientChunkVerdict {
        guard duration >= minimumDuration, sampleCount >= minimumSampleCount else {
            return WatchAmbientChunkVerdict(
                outcome: .insufficient, confidenceScore: 0,
                gaitShare: 0, handShare: 0,
                evidence: ["표본 \(sampleCount)개·\(Int(duration))초"]
            )
        }
        var gait = 0.0
        var hand = 0.0
        var covered = 0.0
        for segment in segments {
            let length = max(0, segment.duration)
            covered += length
            switch group(of: segment) {
            case .gait: gait += length
            case .hand: hand += length
            case .other: break
            }
        }
        let gaitShare = covered > 0 ? gait / covered : 0
        let handShare = covered > 0 ? hand / covered : 0
        let activeShare = gaitShare + handShare
        let deviation = standardDeviationG ?? 0
        var evidence = [
            String(format: "가속도 변동 %.3fg", deviation),
        ]
        if covered > 0 {
            evidence.append("걸음 창 \(percent(gaitShare))%")
            evidence.append("손동작 창 \(percent(handShare))%")
        } else {
            evidence.append("창 판정 없음")
        }
        let isMoving = activeShare >= minimumActiveShare
            || deviation >= movingStandardDeviationG
        guard isMoving else {
            return WatchAmbientChunkVerdict(
                outcome: .still, confidenceScore: 0.6,
                gaitShare: gaitShare, handShare: handShare,
                evidence: evidence + ["움직임 적음"]
            )
        }
        guard gaitShare < maximumGaitShare else {
            return WatchAmbientChunkVerdict(
                outcome: .mostlyGait, confidenceScore: 0.6,
                gaitShare: gaitShare, handShare: handShare,
                evidence: evidence + ["걷기 위주"]
            )
        }
        // 창 근거 없이 변동만으로 본 경우는 낮게, 손동작과 걸음이 함께 보이면 높게.
        let score = covered > 0
            ? min(0.8, 0.5 + 0.3 * min(1, activeShare))
            : 0.5
        return WatchAmbientChunkVerdict(
            outcome: .mixedActivity, confidenceScore: score,
            gaitShare: gaitShare, handShare: handShare,
            evidence: evidence + ["걸음과 손동작이 섞인 움직임"]
        )
    }

    private enum Group { case gait, hand, other }

    private static func group(of segment: WatchBehaviorSegment) -> Group {
        switch segment.behavior {
        case .walking, .running, .stairsUp, .stairsDown:
            return .gait
        case .brushingTeeth, .eating, .typing, .housework, .showering, .exercise:
            return .hand
        case .unknown:
            return segment.evidence.contains(
                WatchBehaviorClassifier.irregularMotionEvidence
            ) ? .hand : .other
        case .stationary, .standing, .sitting, .lying, .sleep,
             .cycling, .elevator, .automotive, .publicTransit, .subway:
            return .other
        }
    }

    private static func percent(_ share: Double) -> Int {
        Int((min(1, max(0, share)) * 100).rounded())
    }
}

extension TaptionWatchStableID {
    /// 평상시 묶음 하나에서 만든 활동 기록의 ID. 세션 ID를 그대로 쓰면 며칠 치 묶음이
    /// 기록 하나로 합쳐진다(WSN1112A01). 보관 표본 ID와 겹치지 않게 한 번 더 섞는다.
    public static func ambientActivityRecord(sessionID: UUID, sequence: Int) -> UUID {
        ambientAccelerationSample(
            sessionID: ambientAccelerationSample(sessionID: sessionID, sequence: sequence),
            sequence: -1
        )
    }
}
