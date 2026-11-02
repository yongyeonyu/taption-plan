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
            [.permissions, .home, .workAndSchool, .salary, .password, .clipEditor, .counters]
        )
        XCTAssertNil(FirstRunTutorialStep.permissions.previous)
        XCTAssertNil(FirstRunTutorialStep.counters.next)
    }

    func testFreshInstallStartsAtPermissions() {
        XCTAssertEqual(decision(), .present(.permissions))
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
        store.save(step: .clipEditor)
        XCTAssertEqual(store.savedStep, .clipEditor)
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
