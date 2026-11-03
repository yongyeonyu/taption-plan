import XCTest
@testable import TaptionPlan

final class FirstRunTutorialTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "FirstRunTutorialTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testStepsFollowRequestedOrder() {
        XCTAssertEqual(
            FirstRunTutorialStep.allCases,
            [
                .welcome, .permissions, .home, .workAndSchool, .salary, .cat,
                .map, .playback, .sidebarCalendar, .clipEditor, .memos, .summary, .counters,
                .calendar, .password, .finish,
            ]
        )
        XCTAssertNil(FirstRunTutorialStep.welcome.previous)
        XCTAssertNil(FirstRunTutorialStep.finish.next)
        XCTAssertEqual(FirstRunTutorialStep.welcome.next, .permissions)
        XCTAssertEqual(FirstRunTutorialStep.finish.previous, .password)
    }

    func testChaptersRunInOrderWithoutGoingBack() {
        let chapters = FirstRunTutorialStep.allCases.map(\.chapter.rawValue)
        XCTAssertEqual(chapters, chapters.sorted())
        XCTAssertEqual(Set(chapters).count, FirstRunTutorialChapter.allCases.count)
    }

    func testFreshInstallStartsAtWelcome() {
        XCTAssertEqual(decision(), .present(.welcome))
    }

    func testOnlyInputStepsOfferStepSkip() {
        let skippable = FirstRunTutorialStep.allCases.filter(\.hasInput)
        XCTAssertEqual(skippable, [.permissions, .home, .workAndSchool, .salary, .cat, .counters, .calendar, .password])
    }

    func testEveryGuideStepHasRowsInBothLanguages() {
        for step in FirstRunTutorialStep.allCases where FirstRunGuideCatalog.isGuide(step) {
            let korean = FirstRunGuideCatalog.rows(for: step, language: .korean)
            let english = FirstRunGuideCatalog.rows(for: step, language: .english)
            XCTAssertFalse(korean.isEmpty, step.rawValue)
            XCTAssertEqual(korean.count, english.count, step.rawValue)
            for (ko, en) in zip(korean, english) {
                XCTAssertNotEqual(ko.title, en.title, step.rawValue)
                XCTAssertNotEqual(ko.detail, en.detail, step.rawValue)
            }
        }
    }

    func testLegacyNumberedStepResumesAtSameContent() {
        let store = FirstRunTutorialStore(defaults: defaults)
        defaults.set(4, forKey: FirstRunTutorialStore.stepKey)
        XCTAssertEqual(store.savedStep, .password)
        defaults.set(6, forKey: FirstRunTutorialStore.stepKey)
        XCTAssertEqual(store.savedStep, .counters)
        defaults.set(99, forKey: FirstRunTutorialStore.stepKey)
        XCTAssertNil(store.savedStep)
    }

    func testPermissionLabelClaimsOnlyWhatIOSReported() {
        func label(_ feature: PermissionFeature, _ state: PermissionState, always: Bool = false) -> String {
            FirstRunTutorialPolicy.permissionLabel(feature, state: state, isLocationAlways: always, language: .korean)
        }
        XCTAssertEqual(label(.location, .authorized), "앱 사용 중에만")
        XCTAssertEqual(label(.location, .authorized, always: true), "항상 허용")
        // iOS는 건강 읽기 허용 여부를 알려 주지 않는다.
        XCTAssertEqual(label(.health, .authorized), "요청함")
        XCTAssertEqual(label(.calendar, .authorized), "허용됨")
        XCTAssertEqual(label(.photos, .limited), "일부 허용")
        for feature in [PermissionFeature.location, .health, .calendar] {
            XCTAssertEqual(label(feature, .denied), "허용 안 함")
            XCTAssertEqual(label(feature, .notDetermined), "아직 안 물음")
        }
    }

    func testExistingInstallIsNotInterrupted() {
        XCTAssertEqual(decision(permissionOnboardingDone: true), .markExistingUser)
        XCTAssertEqual(decision(hasUserData: true), .markExistingUser)
    }

    func testFinishedTutorialNeverReturns() {
        for outcome in [FirstRunTutorialOutcome.completed, .skipped, .existingUser] {
            XCTAssertEqual(decision(outcome: outcome), FirstRunTutorialPolicy.Decision.none)
            XCTAssertEqual(decision(outcome: outcome, savedStep: .salary), FirstRunTutorialPolicy.Decision.none)
        }
    }

    func testInterruptedTutorialResumesEvenAfterRecordsArrive() {
        XCTAssertEqual(decision(savedStep: .password, hasUserData: true), .present(.password))
    }

    func testStoreKeepsStepUntilFinished() {
        let store = FirstRunTutorialStore(defaults: defaults)
        XCTAssertNil(store.savedStep)
        XCTAssertNil(store.outcome)
        store.save(step: .permissions)
        XCTAssertEqual(store.savedStep, .permissions)
        store.save(step: .sidebarCalendar)
        XCTAssertEqual(store.savedStep, .sidebarCalendar)
        store.finish(.skipped)
        XCTAssertEqual(store.outcome, .skipped)
        XCTAssertNil(store.savedStep)
    }

    func testPermissionPromptsWaitForTutorialOnFreshInstallOnly() {
        let store = FirstRunTutorialStore(defaults: defaults)
        XCTAssertTrue(store.defersPermissionPrompts)
        store.finish(.skipped)
        XCTAssertFalse(store.defersPermissionPrompts)
        defaults.removePersistentDomain(forName: suite)
        defaults.set(true, forKey: AppModel.permissionOnboardingKey)
        XCTAssertFalse(store.defersPermissionPrompts)
    }

    func testSkippedPermissionsAreNotAskedAgainUnlessExistingUser() {
        let store = FirstRunTutorialStore(defaults: defaults)
        XCTAssertFalse(store.allowsUnaskedPermissionPrompts)
        for outcome in [FirstRunTutorialOutcome.completed, .skipped] {
            store.finish(outcome)
            XCTAssertFalse(store.allowsUnaskedPermissionPrompts)
        }
        store.finish(.existingUser)
        XCTAssertTrue(store.allowsUnaskedPermissionPrompts)
        defaults.removePersistentDomain(forName: suite)
        defaults.set(true, forKey: AppModel.permissionOnboardingKey)
        XCTAssertTrue(store.allowsUnaskedPermissionPrompts)
    }

    func testDefaultPINIsOnlyRegisteredWithoutExistingPIN() {
        XCTAssertEqual(FirstRunTutorialPolicy.pinToRegister(hasPIN: false), "000000")
        XCTAssertNil(FirstRunTutorialPolicy.pinToRegister(hasPIN: true))
    }

    @MainActor
    func testDefaultPINOpensItsVerifierWithoutEnablingAppLock() throws {
        let service = PlanSecurityService(
            credentialStore: InMemoryCredentialStore(),
            passwordStore: InMemoryCredentialStore(),
            settingsDefaults: defaults
        )
        try service.setPIN(FirstRunTutorialPolicy.defaultPIN)
        XCTAssertTrue(service.hasPIN)
        XCTAssertEqual(service.rememberedPassword, "000000")
        XCTAssertFalse(service.status.settings.lockOnLaunch)
        XCTAssertFalse(service.status.settings.lockOnForeground)
        XCTAssertEqual(service.status.state, .unlocked)
    }

    func testPasswordEntry() {
        typealias Entry = FirstRunTutorialPolicy.PasswordEntry
        XCTAssertEqual(FirstRunTutorialPolicy.passwordEntry(pin: "", confirmation: ""), Entry.keepCurrent)
        XCTAssertEqual(FirstRunTutorialPolicy.passwordEntry(pin: "123456", confirmation: "123456"), Entry.save("123456"))
        XCTAssertEqual(FirstRunTutorialPolicy.passwordEntry(pin: "123456", confirmation: "654321"), Entry.mismatch)
        XCTAssertEqual(FirstRunTutorialPolicy.passwordEntry(pin: "1234", confirmation: "1234"), Entry.incomplete)
        XCTAssertEqual(FirstRunTutorialPolicy.passwordEntry(pin: "123456", confirmation: ""), Entry.incomplete)
    }

    private func decision(
        outcome: FirstRunTutorialOutcome? = nil,
        savedStep: FirstRunTutorialStep? = nil,
        permissionOnboardingDone: Bool = false,
        hasUserData: Bool = false
    ) -> FirstRunTutorialPolicy.Decision {
        FirstRunTutorialPolicy.decision(
            outcome: outcome,
            savedStep: savedStep,
            permissionOnboardingDone: permissionOnboardingDone,
            hasUserData: hasUserData
        )
    }
}

private final class InMemoryCredentialStore: PlanCredentialStore {
    private var data: Data?
    func read() throws -> Data? { data }
    func write(_ data: Data) throws { self.data = data }
}
