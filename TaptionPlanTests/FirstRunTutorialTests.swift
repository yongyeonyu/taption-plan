import CoreLocation
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
                .welcome, .aiConnect, .permissions, .dayCardTime, .home, .workAndSchool, .car, .salary, .cat,
                .map, .playback, .sidebarCalendar, .clipEditor, .memos, .summary, .counters,
                .calendar, .appleWatch, .shortcuts, .password, .finish,
            ]
        )
        XCTAssertNil(FirstRunTutorialStep.welcome.previous)
        XCTAssertNil(FirstRunTutorialStep.finish.next)
        XCTAssertEqual(FirstRunTutorialStep.welcome.next, .aiConnect)
        XCTAssertEqual(FirstRunTutorialStep.aiConnect.next, .permissions)
        XCTAssertEqual(FirstRunTutorialStep.finish.previous, .password)
    }

    func testChaptersRunInOrderWithoutGoingBack() {
        let chapters = FirstRunTutorialStep.allCases.map(\.chapter.rawValue)
        XCTAssertEqual(chapters, chapters.sorted())
        XCTAssertEqual(Set(chapters).count, FirstRunTutorialChapter.allCases.count)
    }

    // AIT1116A01
    func testAIConnectComesRightAfterWelcomeAndHasOwnButtons() {
        XCTAssertEqual(FirstRunTutorialStep.welcome.next, .aiConnect)
        XCTAssertEqual(FirstRunTutorialStep.aiConnect.chapter, .start)
        XCTAssertFalse(FirstRunTutorialStep.aiConnect.hasInput)
    }

    func testSavedAIConnectStepStillResolvesByName() {
        defaults.set("aiConnect", forKey: FirstRunTutorialStore.stepKey)
        XCTAssertEqual(FirstRunTutorialStore(defaults: defaults).savedStep, .aiConnect)
    }

    func testDemoCutsLoopThroughThree() {
        XCTAssertEqual((0..<AIConnectDemoCuts.count).map { AIConnectDemoCuts.next(after: $0) }, [1, 2, 0])
    }

    func testBenefitsAreThreeInBothLanguages() {
        for language in [MapHomeLanguage.korean, .english] {
            let benefits = FirstRunAIConnectPage.benefits(language)
            XCTAssertEqual(benefits.count, 3)
            XCTAssertTrue(benefits.allSatisfy { !$0.title.isEmpty && !$0.detail.isEmpty })
        }
    }

    func testNudgeShowsOnlyOnceAndNeverWhenConnected() {
        XCTAssertTrue(AIConnectNudgePolicy.shouldShow(isConnected: false, alreadyShown: false))
        XCTAssertFalse(AIConnectNudgePolicy.shouldShow(isConnected: true, alreadyShown: false))
        XCTAssertFalse(AIConnectNudgePolicy.shouldShow(isConnected: false, alreadyShown: true))
        AIConnectNudgePolicy.markShown(defaults: defaults)
        XCTAssertTrue(AIConnectNudgePolicy.alreadyShown(defaults: defaults))
    }

    func testFreshInstallStartsAtWelcome() {
        XCTAssertEqual(decision(), .present(.welcome))
    }

    func testOnlyInputStepsOfferStepSkip() {
        let skippable = FirstRunTutorialStep.allCases.filter(\.hasInput)
        XCTAssertEqual(skippable, [.permissions, .dayCardTime, .home, .workAndSchool, .car, .salary, .cat, .counters, .calendar, .appleWatch, .shortcuts, .password])
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

    func testEveryGuideRowHasItsOwnCue() {
        for step in FirstRunTutorialStep.allCases where FirstRunGuideCatalog.isGuide(step) {
            let cues = FirstRunGuideCue.cues(for: step)
            XCTAssertEqual(cues.count, FirstRunGuideCatalog.rows(for: step, language: .korean).count, step.rawValue)
            XCTAssertEqual(Set(cues).count, cues.count, step.rawValue)
        }
        XCTAssertEqual(FirstRunGuideCue.cues(for: .playback), [.play, .record, .render, .save])
        XCTAssertEqual(FirstRunGuideCue.memoAdd.barHighlights, [.memo])
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
        // iOS는 건강 읽기 허용 여부를 알려 주지 않아 물어본 뒤면 허용됨으로 보인다(대표 결정).
        XCTAssertEqual(label(.health, .authorized), "허용됨")
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

    /// REV1102A01: '사용 중' 팝업이 12초를 넘겨 승격을 못 물었으면 튜토리얼 뒤 한 번 더 묻는다.
    func testAlwaysUpgradeIsAllowedOnceAfterTutorialWhenPromptTimedOut() {
        typealias Policy = LocationAlwaysUpgradePolicy
        XCTAssertFalse(Policy.wasRequested(in: defaults), "팝업이 늦게 닫혀 승격을 못 보냈으면 기록이 없다")
        XCTAssertTrue(Policy.shouldRequestAtLaunch(
            status: .authorizedWhenInUse, allowsUnaskedPrompts: false, tutorialFinished: true,
            alreadyRequested: Policy.wasRequested(in: defaults)
        ))
        Policy.markRequested(in: defaults)
        XCTAssertFalse(Policy.shouldRequestAtLaunch(
            status: .authorizedWhenInUse, allowsUnaskedPrompts: false, tutorialFinished: true,
            alreadyRequested: Policy.wasRequested(in: defaults)
        ), "한 번 보낸 뒤에는 다시 묻지 않는다")
        XCTAssertFalse(Policy.shouldRequestAtLaunch(
            status: .authorizedWhenInUse, allowsUnaskedPrompts: false, tutorialFinished: false, alreadyRequested: false
        ), "튜토리얼 중에는 앱이 먼저 묻지 않는다")
        XCTAssertFalse(Policy.shouldRequestAtLaunch(
            status: .notDetermined, allowsUnaskedPrompts: false, tutorialFinished: true, alreadyRequested: false
        ), "튜토리얼에서 건너뛴 첫 권한은 다시 먼저 묻지 않는다")
        XCTAssertTrue(Policy.shouldRequestAtLaunch(
            status: .notDetermined, allowsUnaskedPrompts: true, tutorialFinished: false, alreadyRequested: true
        ))
        for status in [CLAuthorizationStatus.authorizedAlways, .denied, .restricted] {
            XCTAssertFalse(Policy.shouldRequestAtLaunch(
                status: status, allowsUnaskedPrompts: true, tutorialFinished: true, alreadyRequested: false
            ))
        }
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

// MARK: - FRT1117A01

@MainActor
private final class SavedPlaces {
    var names: [String] = []
    var resumeOld: CheckedContinuation<Void, Never>?
}

extension FirstRunTutorialTests {
    /// 검색 결과를 누른 뒤 다른 위치를 고르면, 늦게 끝난 옛 검색이 그 위치를 덮지 않는다.
    @MainActor
    func testLateSearchDoesNotOverwriteLaterChoice() async {
        let selection = FirstRunPlaceSelection()
        let saved = SavedPlaces()
        let old = Task { @MainActor in
            await selection.search({ () async -> String? in
                await withCheckedContinuation { saved.resumeOld = $0 }
                return "옛 검색"
            }, save: { saved.names.append($0 ?? "실패") })
        }
        while saved.resumeOld == nil { await Task.yield() }

        let fresh = await selection.search({ () async -> String? in "새 검색" }, save: { saved.names.append($0 ?? "실패") })
        selection.choose { saved.names.append("지도 핀") }
        saved.resumeOld?.resume()

        let lateApplied = await old.value
        XCTAssertTrue(fresh)
        XCTAssertFalse(lateApplied)
        XCTAssertEqual(saved.names, ["새 검색", "지도 핀"])
    }

    /// 찾지 못한 검색도 마지막 고르기일 때만 알린다.
    @MainActor
    func testOnlyLatestSearchReportsFailure() async {
        let selection = FirstRunPlaceSelection()
        let saved = SavedPlaces()
        let applied = await selection.search({ () async -> String? in nil }, save: { saved.names.append($0 ?? "실패") })
        XCTAssertTrue(applied)
        XCTAssertEqual(saved.names, ["실패"])
    }
}

private final class InMemoryCredentialStore: PlanCredentialStore {
    private var data: Data?
    func read() throws -> Data? { data }
    func write(_ data: Data) throws { self.data = data }

    func testWatchStageFollowsAnswerAndRealInstallState() {
        func stage(_ state: AppleWatchConnectionState, _ answer: Bool?, install: Bool = false) -> FirstRunWatchStage {
            FirstRunWatchStage.make(state: state, hasWatchAnswer: answer, wantsInstall: install)
        }
        XCTAssertEqual(stage(.unsupported, nil), .unavailable)
        XCTAssertEqual(stage(.appNotInstalled, nil), .ask)
        XCTAssertEqual(stage(.notPaired, nil), .ask)
        XCTAssertEqual(stage(.notPaired, false), .skipped)
        XCTAssertEqual(stage(.notPaired, true), .notPaired)
        XCTAssertEqual(stage(.appNotInstalled, true), .explain)
        XCTAssertEqual(stage(.appNotInstalled, true, install: true), .installing)
        // 사용자가 설치하겠다고 해도 실제 설치 전에는 확인으로 넘어가지 않는다.
        XCTAssertNotEqual(stage(.appNotInstalled, true, install: true), .installed)
        for installed in [AppleWatchConnectionState.noRecentData, .background, .reachable] {
            XCTAssertEqual(stage(installed, nil), .installed)
            XCTAssertEqual(stage(installed, false), .installed)
        }
    }
}
