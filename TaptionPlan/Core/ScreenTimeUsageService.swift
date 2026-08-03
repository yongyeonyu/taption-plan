import Foundation

#if canImport(FamilyControls)
import FamilyControls
#endif

enum ScreenTimeAuthorizationState: String, Sendable {
    case unavailable
    case notDetermined
    case denied
    case approved

    var displayName: String {
        switch self {
        case .unavailable: "이 기기에서 지원 안 함"
        case .notDetermined: "권한 필요"
        case .denied: "권한 거부됨"
        case .approved: "권한 승인됨"
        }
    }
}

/// Screen Time is privacy-gated. The app can request Family Controls access,
/// but usage totals are delivered by a DeviceActivityReport extension rather
/// than a background query from the main app.
@MainActor
final class ScreenTimeUsageService {
    var authorizationState: ScreenTimeAuthorizationState {
#if canImport(FamilyControls)
        switch AuthorizationCenter.shared.authorizationStatus {
        case .approved: .approved
        case .denied: .denied
        case .notDetermined: .notDetermined
        @unknown default: .notDetermined
        }
#else
        .unavailable
#endif
    }

    func requestAuthorization() async throws {
#if canImport(FamilyControls)
        try await AuthorizationCenter.shared.requestAuthorization(
            for: .individual
        )
#else
        throw ScreenTimeUsageError.unavailable
#endif
    }
}

enum ScreenTimeUsageError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        "이 기기에서는 앱 사용시간 연동을 사용할 수 없습니다."
    }
}
