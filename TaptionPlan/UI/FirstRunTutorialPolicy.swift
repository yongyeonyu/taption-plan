import Foundation

/// 처음 실행 튜토리얼 단계. 순서는 대표 지시(FRT1102A01).
enum FirstRunTutorialStep: Int, CaseIterable, Identifiable {
    case permissions
    case home
    case workAndSchool
    case salary
    case password
    case clipEditor
    case counters

    var id: Int { rawValue }
    var next: FirstRunTutorialStep? { Self(rawValue: rawValue + 1) }
    var previous: FirstRunTutorialStep? { Self(rawValue: rawValue - 1) }
}

/// 튜토리얼이 어떻게 끝났는지. 값이 있으면 다시 띄우지 않는다.
enum FirstRunTutorialOutcome: String {
    case completed
    case skipped
    /// 튜토리얼 없이 이미 앱을 쓰던 설치.
    case existingUser
}

/// 끝난 결과와 보던 단계를 기기에 남긴다. 권한처럼 기기마다 다르므로 iCloud로 보내지 않는다.
struct FirstRunTutorialStore {
    static let outcomeKey = "taption.firstRunTutorial.outcome"
    static let stepKey = "taption.firstRunTutorial.step"

    var defaults: UserDefaults = .standard

    /// 첫 실행에는 튜토리얼이 권한을 물을 때까지 앱이 먼저 시스템 팝업을 띄우지 않는다.
    var defersPermissionPrompts: Bool {
        guard outcome == nil else { return false }
        return !defaults.bool(forKey: AppModel.permissionOnboardingKey)
    }

    /// 튜토리얼을 거친 사람이 건너뛴 권한은 앱이 다시 먼저 묻지 않는다. 직접 켜거나 누를 때만 묻는다.
    var allowsUnaskedPermissionPrompts: Bool {
        switch outcome {
        case .existingUser: true
        case nil: defaults.bool(forKey: AppModel.permissionOnboardingKey)
        case .completed, .skipped: false
        }
    }

    var outcome: FirstRunTutorialOutcome? {
        defaults.string(forKey: Self.outcomeKey).flatMap(FirstRunTutorialOutcome.init(rawValue:))
    }

    var savedStep: FirstRunTutorialStep? {
        guard defaults.object(forKey: Self.stepKey) != nil else { return nil }
        return FirstRunTutorialStep(rawValue: defaults.integer(forKey: Self.stepKey))
    }

    func save(step: FirstRunTutorialStep) {
        defaults.set(step.rawValue, forKey: Self.stepKey)
    }

    func finish(_ outcome: FirstRunTutorialOutcome) {
        defaults.set(outcome.rawValue, forKey: Self.outcomeKey)
        defaults.removeObject(forKey: Self.stepKey)
    }
}

enum FirstRunTutorialPolicy {
    /// 비밀번호가 없는 설치의 초기값(대표 지시). 앱 잠금은 켜지 않는다.
    static let defaultPIN = "000000"

    enum Decision: Equatable {
        case present(FirstRunTutorialStep)
        case markExistingUser
        case none
    }

    /// 시작하다 만 튜토리얼은 그 사이 기록이 쌓였어도 이어서 보여 준다.
    static func decision(
        outcome: FirstRunTutorialOutcome?,
        savedStep: FirstRunTutorialStep?,
        permissionOnboardingDone: Bool,
        hasUserData: Bool
    ) -> Decision {
        if outcome != nil { return .none }
        if let savedStep { return .present(savedStep) }
        if permissionOnboardingDone || hasUserData { return .markExistingUser }
        return .present(.permissions)
    }

    /// 등록된 비밀번호는 덮어쓰지 않는다. 다시 설치해도 Keychain에 남아 있을 수 있다.
    static func pinToRegister(hasPIN: Bool) -> String? {
        hasPIN ? nil : defaultPIN
    }

    enum PasswordEntry: Equatable {
        case keepCurrent
        case save(String)
        case incomplete
        case mismatch
    }

    static func passwordEntry(pin: String, confirmation: String) -> PasswordEntry {
        if pin.isEmpty, confirmation.isEmpty { return .keepCurrent }
        guard PlanPINVerifier.isValid(pin), PlanPINVerifier.isValid(confirmation) else { return .incomplete }
        return pin == confirmation ? .save(pin) : .mismatch
    }
}
