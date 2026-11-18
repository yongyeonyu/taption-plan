import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple 모델 3단계 길(PCC1118A01)에 넣을 지금 조건을 iOS에서 읽는다. 판단은 `AppleModelRouter`가 한다.
/// `PrivateCloudComputeLanguageModel`은 iOS 27 SDK(Swift 6.4)에만 있어 CI의 Xcode 26에서는 빠진다.
enum AppleModelEnvironment {
    /// PCC entitlement 승인 전에는 PCC를 부르지 않는다(대표 결정 2026-11-18). 승인 뒤 entitlement를 넣는 커밋에서 켠다.
    static let isPrivateCloudComputeEnabled = false

    @MainActor
    static func conditions(_ task: AppleModelTask, text: String, cloudEnabled: Bool = isPrivateCloudComputeEnabled) -> AppleModelConditions {
        AppleModelConditions(
            task: task,
            cloud: cloudState(enabled: cloudEnabled),
            device: deviceState(),
            isOnline: OfflineVectorNetworkStatus.shared.current.isOnline,
            inputLength: text.count,
            allowsCloud: allowsCloud(for: text)
        )
    }

    /// 글에 좌표가 있으면 기기 밖(Apple 서버)으로 보내지 않는다. AI 공유 수준과는 상관없다(대표 결정 2026-11-18).
    static func allowsCloud(for text: String) -> Bool {
        !AppleModelRouter.containsCoordinates(text)
    }

    /// 스위치가 꺼져 있으면 PCC를 묻지도 않고 「쓸 수 없음」으로 둔다.
    static func cloudState(enabled: Bool = isPrivateCloudComputeEnabled) -> AppleCloudModelState {
        guard enabled else { return .unavailable }
        #if canImport(FoundationModels) && compiler(>=6.4)
        if #available(iOS 27.0, *) { return AppleCloudModel.state(PrivateCloudComputeLanguageModel()) }
        #endif
        return .unsupported
    }

    static func deviceState() -> AppleDeviceModelState {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) { return mapped(SystemLanguageModel.default.availability) }
        #endif
        return .unsupported
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    static func mapped(_ availability: SystemLanguageModel.Availability) -> AppleDeviceModelState {
        switch availability {
        case .available: .available
        case .unavailable(.appleIntelligenceNotEnabled), .unavailable(.modelNotReady): .unavailable
        case .unavailable: .unsupported
        }
    }
    #endif
}

/// Private Cloud Compute 모델 호출. 한도·네트워크·서비스 거절은 `Failure`로 던져 다음 길로 넘긴다.
enum AppleCloudModel {
    struct Failure: Error, Equatable {
        var reason: AppleCloudFailure
    }

    static func polishMemo(_ text: String) async throws -> String {
        #if canImport(FoundationModels) && compiler(>=6.4)
        if #available(iOS 27.0, *) {
            let session = LanguageModelSession(model: PrivateCloudComputeLanguageModel(), instructions: MemoPolishFormat.instructions(for: text))
            do {
                return try await FoundationMemoPolisher.draft(text, in: session)
            } catch {
                throw classified(error)
            }
        }
        #endif
        throw Failure(reason: .service)
    }
}

#if canImport(FoundationModels) && compiler(>=6.4)
@available(iOS 27.0, *)
extension AppleCloudModel {
    static func state(_ model: PrivateCloudComputeLanguageModel) -> AppleCloudModelState {
        switch model.availability {
        case .available: .available(quota(model.quotaUsage))
        case .unavailable: .unavailable
        }
    }

    static func quota(_ usage: PrivateCloudComputeLanguageModel.QuotaUsage) -> AppleCloudQuota {
        switch usage.status {
        case .belowLimit(let below): below.isApproachingLimit ? .approachingLimit : .belowLimit
        case .limitReached: .limitReached(resetDate: usage.resetDate)
        @unknown default: usage.isLimitReached ? .limitReached(resetDate: usage.resetDate) : .belowLimit
        }
    }

    /// 글 내용 때문의 거절(가드레일·언어·길이)은 안내로 그대로 두고, 그 밖(entitlement 없음 포함)은 다음 길로 넘긴다.
    static func classified(_ error: Error) -> Error {
        if error is CancellationError { return error }
        if let error = error as? PrivateCloudComputeLanguageModel.Error {
            switch error {
            case .quotaLimitReached(let reached): return Failure(reason: .quotaReached(resetDate: reached.resetDate))
            case .networkFailure: return Failure(reason: .network)
            case .serviceUnavailable: return Failure(reason: .service)
            @unknown default: return Failure(reason: .service)
            }
        }
        let notice = FoundationMemoPolisher.notice(for: error)
        if let notice = notice as? MemoPolishNotice, notice == .failed { return Failure(reason: .service) }
        return notice
    }
}
#endif
