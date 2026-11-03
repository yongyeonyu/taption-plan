import Foundation

/// 처음 실행 튜토리얼의 묶음. 무엇부터 할지 이 순서로 알려 준다(FRT1104A01).
enum FirstRunTutorialChapter: Int, CaseIterable {
    case start
    case setup
    case learn
    case connect
    case finish
}

/// 처음 실행 튜토리얼 단계. 저장 값이 이름이라 순서를 바꿔도 이어 보기가 어긋나지 않는다.
enum FirstRunTutorialStep: String, CaseIterable, Identifiable {
    case welcome
    case permissions
    case home
    case workAndSchool
    case salary
    case cat
    case map
    case playback
    case sidebarCalendar
    case clipEditor
    case memos
    case summary
    case counters
    case calendar
    case password
    case finish

    /// FRT1102A01이 번호로 저장하던 단계.
    static let legacyOrder: [FirstRunTutorialStep] = [
        .permissions, .home, .workAndSchool, .salary, .password, .clipEditor, .counters,
    ]

    var id: String { rawValue }
    var number: Int { Self.allCases.firstIndex(of: self)! + 1 }
    var next: FirstRunTutorialStep? { number < Self.allCases.count ? Self.allCases[number] : nil }
    var previous: FirstRunTutorialStep? { number > 1 ? Self.allCases[number - 2] : nil }

    var chapter: FirstRunTutorialChapter {
        switch self {
        case .welcome: .start
        case .permissions, .home, .workAndSchool, .salary, .cat: .setup
        case .map, .playback, .sidebarCalendar, .clipEditor, .memos, .summary, .counters: .learn
        case .calendar, .password: .connect
        case .finish: .finish
        }
    }

    /// 입력이 있는 단계에만 건너뛰기를 둔다. 설명 단계는 다음이 곧 건너뛰기다.
    var hasInput: Bool {
        switch self {
        case .permissions, .home, .workAndSchool, .salary, .cat, .counters, .calendar, .password: true
        default: false
        }
    }
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
        guard let raw = defaults.string(forKey: Self.stepKey) else { return nil }
        if let step = FirstRunTutorialStep(rawValue: raw) { return step }
        let legacy = FirstRunTutorialStep.legacyOrder
        return Int(raw).flatMap { legacy.indices.contains($0) ? legacy[$0] : nil }
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
        return .present(.welcome)
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

    /// 권한 줄의 상태 문구. iOS가 알려 준 값만 말한다. 건강 읽기는 iOS가 허용 여부를 알려 주지 않아 요청 사실만 말한다.
    static func permissionLabel(
        _ feature: PermissionFeature,
        state: PermissionState,
        isLocationAlways: Bool,
        language: MapHomeLanguage
    ) -> String {
        switch state {
        case .notDetermined:
            return language.text("아직 안 물음", "Not asked")
        case .denied:
            return language.text("허용 안 함", "Not allowed")
        case .limited:
            return language.text("일부 허용", "Partly allowed")
        case .unavailable:
            return language.text("사용 불가", "Unavailable")
        case .authorized:
            switch feature {
            case .location where isLocationAlways: return language.text("항상 허용", "Always")
            case .location: return language.text("앱 사용 중에만", "While using")
            case .health: return language.text("요청함", "Requested")
            default: return language.text("허용됨", "Allowed")
            }
        }
    }
}
