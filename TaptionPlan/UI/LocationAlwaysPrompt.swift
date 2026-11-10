import SwiftUI

/// 위치가 「항상 허용」이 아니면 기록이 제한된다고 알리고 iOS 설정으로 보낸다(LOC1110A01).
/// iOS가 가끔 띄우는 「백그라운드에서 위치를 n번 사용」 창은 시스템 개인정보 알림이라 앱이 끌 수 없다.
enum LocationAlwaysPrompt {
    private static let lastShownKey = "locationAlwaysPromptLastShown"

    static var settingsURL: URL? { URL(string: UIApplication.openSettingsURLString) }

    /// 위치를 물어본 뒤 「항상」이 아니면, 하루 한 번만 묻는다.
    static func shouldPrompt(state: PermissionState, isAlways: Bool, now: Date = .now, defaults: UserDefaults = .standard) -> Bool {
        guard state != .notDetermined, state != .unavailable, !isAlways else { return false }
        return defaults.string(forKey: lastShownKey) != dayKey(now)
    }

    static func markShown(now: Date = .now, defaults: UserDefaults = .standard) {
        defaults.set(dayKey(now), forKey: lastShownKey)
    }

    private static func dayKey(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return "\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
    }

    static func message(_ language: MapHomeLanguage) -> String {
        language.text(
            "위치가 '항상 허용'이 아니면 앱을 닫았을 때 이동·머문 곳 기록이 제한돼요. 설정 → 위치에서 '항상'으로 바꿔 주세요.",
            "Unless location is set to Always, places and routes aren't recorded while the app is closed. In Settings → Location, choose Always."
        )
    }
}

extension MapHomeView {
    func checkLocationAlways() async {
        guard !FirstRunTutorialStore().defersPermissionPrompts else { return }
        try? await Task.sleep(for: .seconds(3))
        await model.refreshPermissions()
        guard LocationAlwaysPrompt.shouldPrompt(
            state: model.permissionState(for: .location),
            isAlways: model.sensorService?.hasAlwaysLocationAuthorization() == true
        ) else { return }
        LocationAlwaysPrompt.markShown()
        isLocationAlwaysPromptPresented = true
    }
}
