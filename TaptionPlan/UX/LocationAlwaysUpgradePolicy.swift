import CoreLocation
import Foundation

/// 위치 '항상' 승격 요청을 언제 한 번 보낼지 정한다(REV1102A01).
///
/// iOS는 승격 팝업을 설치당 한 번만 보여 주므로, 실제로 '항상' 요청을 보낸 때만 기록한다.
/// '사용 중' 팝업이 12초 대기보다 오래 떠 있으면 같은 호출에서 승격을 묻지 못하는데,
/// 예전에는 그 전에 기록부터 남겨 다시는 묻지 못했다.
enum LocationAlwaysUpgradePolicy {
    static let requestedKey = "taption.locationAlwaysUpgradeRequested"

    /// 시작할 때 위치 권한을 물을지.
    /// - 처음 묻는 '사용 중' 팝업은 앱이 먼저 물어도 되는 설치에서만 띄운다.
    /// - '사용 중'만 받은 상태의 '항상' 승격은 아직 보낸 적이 없으면 튜토리얼을 마친 뒤에도 한 번 허용한다.
    static func shouldRequestAtLaunch(
        status: CLAuthorizationStatus,
        allowsUnaskedPrompts: Bool,
        tutorialFinished: Bool,
        alreadyRequested: Bool
    ) -> Bool {
        switch status {
        case .notDetermined:
            return allowsUnaskedPrompts
        case .authorizedWhenInUse:
            return !alreadyRequested && (allowsUnaskedPrompts || tutorialFinished)
        default:
            return false
        }
    }

    static func markRequested(in defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: requestedKey)
    }

    static func wasRequested(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: requestedKey)
    }
}
