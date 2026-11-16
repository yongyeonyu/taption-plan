import ActivityKit
import Foundation
import OSLog
import SwiftUI
import TaptionPlanCore

enum TaptionWidgetCatAction: String, CaseIterable, Equatable, Sendable {
    case walking
    case running
    case sitting
    case sleeping
    case grooming
    case eating
    case startled
    case ballPlay
    case fishingPlay
    case stretching
    case kneading
    case yawning

    var movesAcrossTrack: Bool {
        self == .walking || self == .running
    }

    var previewTitle: String {
        switch self {
        case .walking: "걷기"
        case .running: "달리기"
        case .sitting: "앉아있기"
        case .sleeping: "잠자기"
        case .grooming: "그루밍"
        case .eating: "밥 먹기"
        case .startled: "너구리 꼬리"
        case .ballPlay: "공 잡는 놀이"
        case .fishingPlay: "낚싯대 놀이"
        case .stretching: "기지개"
        case .kneading: "꾹꾹이"
        case .yawning: "하품"
        }
    }

    var previewSystemImage: String {
        switch self {
        case .walking: "figure.walk"
        case .running: "figure.run"
        case .sitting: "pawprint.fill"
        case .sleeping: "moon.zzz.fill"
        case .grooming: "sparkles"
        case .eating: "fork.knife"
        case .startled: "exclamationmark.bubble.fill"
        case .ballPlay: "circle.fill"
        case .fishingPlay: "fish.fill"
        case .stretching: "figure.flexibility"
        case .kneading: "hand.tap.fill"
        case .yawning: "mouth.fill"
        }
    }

    /// 렌더러가 쓰는 동작 이름. 두 열거형의 rawValue는 항상 같아야 한다.
    var animationAction: TaptionCatAnimationAction {
        TaptionCatAnimationAction(rawValue: rawValue) ?? .walking
    }
}

enum TaptionWidgetCatActionSelector {
    static func preferredAction(
        categoryID: String,
        title: String
    ) -> TaptionWidgetCatAction? {
        let category = categoryID.lowercased()
        let normalizedTitle = title.lowercased()

        if containsAny(
            normalizedTitle,
            ["밥", "식사", "간식", "요리", "카페"]
        ) {
            return .eating
        }
        if containsAny(normalizedTitle, ["잠", "수면", "취침", "낮잠"]) {
            return .sleeping
        }
        if containsAny(normalizedTitle, ["달리", "러닝", "조깅"]) {
            return .running
        }
        if containsAny(normalizedTitle, ["걷", "산책", "도보"]) {
            return .walking
        }
        if containsAny(
            normalizedTitle,
            ["축구", "농구", "야구", "테니스", "공놀이", "헬스", "운동"]
        ) {
            return .ballPlay
        }
        if containsAny(
            normalizedTitle,
            ["낚시", "놀이", "게임", "음악", "사진", "여행"]
        ) {
            return .fishingPlay
        }
        if containsAny(
            normalizedTitle,
            ["샤워", "세면", "씻기", "미용", "단장", "청소"]
        ) {
            return .grooming
        }
        if containsAny(normalizedTitle, ["스트레칭", "요가", "기지개"]) {
            return .stretching
        }
        if containsAny(normalizedTitle, ["명상", "휴식", "쉬기"]) {
            return .kneading
        }

        return switch category {
        case "exercise", "health": .ballPlay
        case "hobby", "travel", "photo", "event", "relationship":
            .fishingPlay
        case "sleep", "rest": .sleeping
        case "routine": .grooming
        case "movement": .walking
        case "project", "study", "location": .sitting
        default: nil
        }
    }

    private static func containsAny(
        _ value: String,
        _ candidates: [String]
    ) -> Bool {
        candidates.contains { value.contains($0) }
    }
}

struct TaptionWidgetCatWalkPose: Equatable, Sendable {
    var progress: Double
    var facesLeft: Bool
    var legPhase: Int
    var isAtEndpoint: Bool
    var action: TaptionWidgetCatAction
    var tailSwing: Double
    var headTiltDegrees: Double
    var legSwing: Double = 0
    var idle: TaptionCatIdleBeat = .still
}

enum TaptionWidgetCatWalkEngine {
    static let defaultStepDuration: TimeInterval = 0.5
    static let movementStepCount = 20
    static let stepCount = 40
    // Keep an action pose visible at each end of the track, but do not spend
    // half of the 20-second cycle parked there.  A long rest phase made the
    // widget cat look frozen whenever the current action was sitting,
    // sleeping, or another non-locomotion action.
    static let endpointActionHoldSteps = 4
    static let roundTripDuration =
        defaultStepDuration * Double(movementStepCount)
    static let sequenceDuration = defaultStepDuration * Double(stepCount)

    static func pose(
        at date: Date,
        stepDuration: TimeInterval = defaultStepDuration,
        preferredAction: TaptionWidgetCatAction? = nil
    ) -> TaptionWidgetCatWalkPose {
        let duration = max(0.5, stepDuration)
        let rawStep = Int64(date.timeIntervalSinceReferenceDate / duration)
        let count = Int64(stepCount)
        let step = Int(((rawStep % count) + count) % count)
        let cycle = rawStep / count
        let progress: Double
        let facesLeft: Bool
        let isAtEndpoint: Bool
        let action: TaptionWidgetCatAction

        switch step {
        case 0...9:
            progress = Double(step) / 9
            facesLeft = false
            isAtEndpoint = step == 0 || step == 9
            action = preferredAction == .running ? .running : .walking
        case 10:
            progress = 1
            facesLeft = true
            isAtEndpoint = true
            action = .startled
        case 11...19:
            progress = Double(19 - step) / 8
            facesLeft = true
            isAtEndpoint = step == 11 || step == 19
            action = preferredAction == .walking ? .walking : .running
        case movementStepCount..<movementStepCount + endpointActionHoldSteps:
            progress = 0
            facesLeft = false
            isAtEndpoint = step == movementStepCount
            action = restAction(
                preferred: preferredAction,
                cycle: cycle,
                slot: 0
            )
        case movementStepCount + endpointActionHoldSteps...29:
            progress = Double(
                step - (movementStepCount + endpointActionHoldSteps - 1)
            ) / 6
            facesLeft = false
            isAtEndpoint = step == 29
            action = .walking
        case 30..<30 + endpointActionHoldSteps:
            progress = 1
            facesLeft = true
            isAtEndpoint = step == 30
            action = restAction(
                preferred: preferredAction,
                cycle: cycle,
                slot: 1
            )
        default:
            progress = Double(39 - step) / 6
            facesLeft = true
            isAtEndpoint = step == 39
            action = .running
        }
        let phase = step % TaptionCatAnimationEngine.phaseCount
        let motion = motionDetails(for: action, phase: phase)
        return TaptionWidgetCatWalkPose(
            progress: min(1, max(0, progress)),
            facesLeft: facesLeft,
            legPhase: phase,
            isAtEndpoint: isAtEndpoint,
            action: action,
            tailSwing: motion.tailSwing,
            headTiltDegrees: motion.headTiltDegrees,
            legSwing: motion.legSwing,
            idle: TaptionCatIdleBeat.beat(at: date)
        )
    }

    static func motionDetails(
        for action: TaptionWidgetCatAction,
        phase: Int
    ) -> TaptionCatMotionDetails {
        TaptionCatAnimationEngine.motionDetails(
            for: action.animationAction,
            phase: phase
        )
    }

    private static func restAction(
        preferred: TaptionWidgetCatAction?,
        cycle: Int64,
        slot: Int64
    ) -> TaptionWidgetCatAction {
        if let preferred {
            return switch preferred {
            case .walking, .running: .sitting
            default: preferred
            }
        }
        let actions: [TaptionWidgetCatAction] = [
            .sitting,
            .grooming,
            .eating,
            .sleeping,
            .ballPlay,
            .fishingPlay,
            .stretching,
            .kneading,
            .yawning,
        ]
        let seed = abs((cycle &* 31) &+ (slot &* 17))
        return actions[Int(seed % Int64(actions.count))]
    }
}
