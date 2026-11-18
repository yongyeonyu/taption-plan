import Foundation

/// 유료 외부 API 없이 Apple 모델을 먼저 쓰는 3단계 길(PCC1118A01).
/// 1순위 Private Cloud Compute, 2순위 기기 안 모델, 3순위 연결된 AI 중계 큐(`AITaskQueue`·메모 다듬기 목록).
/// 판단만 한다. 모델을 부르지 않고 FoundationModels도 모른다. 실제 호출은 앱의 얇은 층이 한다.
public enum AppleModelTask: String, CaseIterable, Sendable {
    case memoPolish
    /// 지출·일정 초안 뽑기(단순 분류).
    case draftExtraction
    case daySummary

    /// 기기 안 모델(문맥 4K)에 맡길 입력 글자 수. 0이면 기기에서 하지 않는다.
    public var onDeviceInputLimit: Int {
        switch self {
        case .memoPolish: 1_500
        case .draftExtraction: 1_200
        case .daySummary: 0
        }
    }

    /// PCC에 보낼 입력 글자 수.
    public var cloudInputLimit: Int { 12_000 }
}

/// PCC 모델 상태. iOS가 알려 준 것만 옮긴다.
public enum AppleCloudModelState: Equatable, Sendable {
    /// iOS 27 미만·프레임워크 없음.
    case unsupported
    /// 기기 조건·시스템 준비 안 됨·entitlement 없음.
    case unavailable
    case available(AppleCloudQuota)
}

public enum AppleCloudQuota: Equatable, Sendable {
    case belowLimit
    case approachingLimit
    case limitReached(resetDate: Date?)
}

public enum AppleDeviceModelState: Equatable, Sendable {
    /// iOS 26 미만·미지원 기기·지역.
    case unsupported
    /// Apple Intelligence 꺼짐·모델 준비 중.
    case unavailable
    case available
}

public struct AppleModelConditions: Equatable, Sendable {
    public var task: AppleModelTask
    public var cloud: AppleCloudModelState
    public var device: AppleDeviceModelState
    public var isOnline: Bool
    public var inputLength: Int
    /// 기기 밖(Apple 서버)으로 보내도 되는가. AI 공유 수준 「끔」이거나 글에 좌표가 있으면 false.
    public var allowsCloud: Bool

    public init(task: AppleModelTask, cloud: AppleCloudModelState, device: AppleDeviceModelState,
                isOnline: Bool, inputLength: Int, allowsCloud: Bool = true) {
        self.task = task
        self.cloud = cloud
        self.device = device
        self.isOnline = isOnline
        self.inputLength = inputLength
        self.allowsCloud = allowsCloud
    }
}

public enum AppleModelRoute: String, Sendable {
    case privateCloud
    case onDevice
    case relayQueue
}

/// Alert 없이 화면 한 줄로 알릴 것.
public enum AppleModelNotice: Equatable, Sendable {
    case cloudQuotaApproaching
    case cloudQuotaReached(resetDate: Date?)
    case inputTooLongForDevice
}

public struct AppleModelDecision: Equatable, Sendable {
    public var route: AppleModelRoute
    public var notice: AppleModelNotice?

    public init(_ route: AppleModelRoute, notice: AppleModelNotice? = nil) {
        self.route = route
        self.notice = notice
    }
}

/// PCC를 불렀다가 실패한 까닭.
public enum AppleCloudFailure: Equatable, Sendable {
    case quotaReached(resetDate: Date?)
    case network
    /// 서비스 중단·entitlement 없음 등 그 밖의 거절.
    case service
}

public enum AppleModelRouter {
    public static func decide(_ conditions: AppleModelConditions) -> AppleModelDecision {
        let length = conditions.inputLength
        var notice: AppleModelNotice?
        if case .available(let quota) = conditions.cloud, conditions.allowsCloud {
            switch quota {
            case .limitReached(let resetDate):
                notice = .cloudQuotaReached(resetDate: resetDate)
            case .belowLimit, .approachingLimit:
                if conditions.isOnline, length > 0, length <= conditions.task.cloudInputLimit {
                    return AppleModelDecision(.privateCloud, notice: quota == .approachingLimit ? .cloudQuotaApproaching : nil)
                }
            }
        }
        if conditions.device == .available, length > 0 {
            if length <= conditions.task.onDeviceInputLimit { return AppleModelDecision(.onDevice, notice: notice) }
            if conditions.task.onDeviceInputLimit > 0, notice == nil { notice = .inputTooLongForDevice }
        }
        return AppleModelDecision(.relayQueue, notice: notice)
    }

    /// PCC가 실패하면 그 까닭을 조건에 넣고 다시 고른다. 다시 PCC가 나오지 않는다.
    public static func decide(after failure: AppleCloudFailure, _ conditions: AppleModelConditions) -> AppleModelDecision {
        var next = conditions
        switch failure {
        case .quotaReached(let resetDate): next.cloud = .available(.limitReached(resetDate: resetDate))
        case .network:
            next.cloud = .unavailable
            next.isOnline = false
        case .service: next.cloud = .unavailable
        }
        return decide(next)
    }

    /// 글에 위도·경도 쌍처럼 보이는 것이 있는가. 있으면 기기 밖 AI로 보내지 않는다.
    public static func containsCoordinates(_ text: String) -> Bool {
        text.range(of: #"-?\d{1,3}\.\d{4,}\s*[,/ ]\s*-?\d{1,3}\.\d{4,}"#, options: .regularExpression) != nil
    }
}
