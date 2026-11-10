import XCTest
@testable import TaptionPlan

/// 백업 비밀번호 보관과 「비밀번호를 잊었어요」(BKP1110A02).
/// 실제 Face ID와 iCloud 키체인 동기화는 실기기에서만 확인할 수 있어 여기서는 가짜 저장소·가짜 본인 확인을 쓴다.
@MainActor
final class BackupPasswordVaultTests: XCTestCase {
    private final class FakeStore: BackupPasswordStore {
        var value: String?
        func read() throws -> String? { value }
        func write(_ password: String) throws { value = password }
        func delete() throws { value = nil }
    }

    private struct FakeAuthenticator: AssistantOwnerAuthenticating {
        let result: AssistantOwnerAuthResult
        func authenticate(reason: String) async -> AssistantOwnerAuthResult { result }
    }

    private let password = "482915"
    private var directories: [URL] = []

    override func tearDown() async throws {
        await MainActor.run {
            directories.forEach { try? FileManager.default.removeItem(at: $0) }
            directories = []
        }
        try await super.tearDown()
    }

    private func vault(_ store: FakeStore, _ result: AssistantOwnerAuthResult = .passed) -> BackupPasswordVault {
        BackupPasswordVault(store: store, authenticator: FakeAuthenticator(result: result))
    }

    private func service(
        credentials: PlanCredentialStore = InMemoryPlanCredentialStore(), store: FakeStore
    ) -> PlanSecurityService {
        let suite = "BackupPasswordVaultTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return PlanSecurityService(
            credentialStore: credentials, backupPasswordVault: vault(store),
            biometricAuthenticator: MockPlanLocalBiometricAuthenticator(), settingsDefaults: defaults
        )
    }

    func testSaveReadAndDeleteThroughStore() async {
        let store = FakeStore()
        let vault = vault(store)
        XCTAssertNil(vault.stored)
        XCTAssertTrue(vault.save(password))
        XCTAssertEqual(store.value, password)
        XCTAssertEqual(vault.stored, password)
        let shown = await vault.reveal(reason: "")
        XCTAssertEqual(shown, .revealed(password))
        vault.clear()
        XCTAssertNil(store.value)
        XCTAssertNil(vault.stored)
    }

    func testSaveRejectsValuesThatAreNotAPassword() {
        let store = FakeStore()
        let vault = vault(store)
        XCTAssertFalse(vault.save("12345"))
        XCTAssertFalse(vault.save("12345a"))
        XCTAssertFalse(vault.save(""))
        XCTAssertNil(store.value)
    }

    func testRevealIsDeniedWhenOwnerCheckFails() async {
        let store = FakeStore()
        store.value = password
        let failed = await vault(store, .failed).reveal(reason: "") { self.password }
        XCTAssertEqual(failed, .denied)
        let noPasscode = await vault(store, .noPasscode).reveal(reason: "") { self.password }
        XCTAssertEqual(noPasscode, .passcodeNotSet)
    }

    func testRevealSaysNothingStoredWhenEmpty() async {
        let store = FakeStore()
        let empty = await vault(store).reveal(reason: "")
        XCTAssertEqual(empty, .nothingStored)
        let denied = await vault(store, .failed).reveal(reason: "")
        XCTAssertEqual(denied, .denied, "본인 확인 전에는 보관 여부도 알려 주지 않는다")
    }

    func testRevealMovesTheDeviceOnlyValueIntoTheVault() async {
        let store = FakeStore()
        let shown = await vault(store).reveal(reason: "") { self.password }
        XCTAssertEqual(shown, .revealed(password))
        XCTAssertEqual(store.value, password)
    }

    func testSettingAndChangingThePasswordSavesIt() throws {
        let store = FakeStore()
        let service = service(store: store)
        try service.setPIN(password)
        XCTAssertEqual(store.value, password)
        try service.setPIN("739104")
        XCTAssertEqual(store.value, "739104")
        XCTAssertThrowsError(try service.setPIN("12"))
        XCTAssertEqual(store.value, "739104")
    }

    func testExistingPasswordIsSavedWhenItIsVerified() throws {
        let credentials = InMemoryPlanCredentialStore()
        try service(credentials: credentials, store: FakeStore()).setPIN(password)
        let store = FakeStore()
        let existing = service(credentials: credentials, store: store)
        XCTAssertNil(store.value)
        XCTAssertThrowsError(try existing.verifyPIN("000000", unlocking: false))
        XCTAssertNil(store.value)
        try existing.verifyPIN(password, unlocking: false)
        XCTAssertEqual(store.value, password)
    }

    func testOpenedPasswordDoesNotReplaceTheRegisteredOne() throws {
        let store = FakeStore()
        let service = service(store: store)
        try service.setPIN(password)
        service.keepOpenedBackupPassword("111111")
        XCTAssertEqual(store.value, password)
        store.value = nil
        service.keepOpenedBackupPassword(password)
        XCTAssertEqual(store.value, password)
    }

    func testListingAndRestoreWithATypedPasswordSaveIt() async throws {
        let backups = try makeDirectory().appendingPathComponent("backups", isDirectory: true)
        let source = try makeModel(backups: backups, store: FakeStore())
        try source.model.configureBackupPIN(password)
        let day = Date(timeIntervalSince1970: 1_790_000_000)
        try await source.store.appendImmutableReadings([SensorReading(
            timestamp: day,
            point: GeoPoint(latitude: 37.5665, longitude: 126.978, altitude: 20, horizontalAccuracy: 5, verticalAccuracy: 3),
            motion: .walking, motionConfidence: .high, sequence: 1
        )])
        await source.model.backUpNow(password: password, now: day.addingTimeInterval(86_400))
        XCTAssertEqual(source.model.lastBackupReport?.succeeded, true)

        // 비밀번호를 등록한 적 없는 새 기기.
        let listed = FakeStore()
        let target = try makeModel(backups: backups, store: listed)
        await target.model.refreshBackupListings(password: "000000")
        let scope = try XCTUnwrap(target.model.backupListings.first?.scope)
        XCTAssertNil(listed.value, "열리지 않은 비밀번호는 보관하지 않는다")
        await target.model.restoreBackup(scope, password: "000000")
        XCTAssertNil(listed.value)
        await target.model.refreshBackupListings(password: password)
        XCTAssertEqual(listed.value, password)

        listed.value = nil
        await target.model.restoreBackup(scope, password: password)
        XCTAssertEqual(target.model.lastBackupReport?.succeeded, true)
        XCTAssertEqual(listed.value, password)
        let shown = await target.model.revealBackupPassword()
        XCTAssertEqual(shown, .revealed(password))
    }

    /// 시뮬레이터 키체인에 동기화 항목으로 쓰고 읽고 지운다(iCloud로 실제 올라가는지는 확인하지 못한다).
    func testKeychainStoreRoundTrip() throws {
        let store = KeychainBackupPasswordStore(account: "backup-password-test-\(UUID().uuidString)")
        defer { try? store.delete() }
        XCTAssertNil(try store.read())
        try store.write(password)
        XCTAssertEqual(try store.read(), password)
        try store.write("739104")
        XCTAssertEqual(try store.read(), "739104")
        try store.delete()
        XCTAssertNil(try store.read())
        XCTAssertNoThrow(try store.delete())
    }

    func testEveryOutcomeButRevealHasAMessage() {
        for outcome in [BackupPasswordReveal.nothingStored, .passcodeNotSet, .denied] {
            XCTAssertFalse(BackupPasswordForgotView.message(for: outcome, language: .korean).isEmpty)
        }
    }

    // MARK: 준비

    private func makeDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("taption-vault-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        directories.append(root)
        return root
    }

    private func makeModel(backups: URL, store vaultStore: FakeStore) throws -> (model: AppModel, store: TaptionStoreV2) {
        let root = try makeDirectory()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Seoul"))
        let store = try TaptionStoreV2(url: root.appendingPathComponent("store.sqlite"), calendar: calendar)
        let temporary = root.appendingPathComponent("tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        var configuration = TaptionBackupEngine.Configuration()
        configuration.iterations = 1_000
        configuration.minimumIterations = 1
        configuration.temporaryDirectory = temporary
        let engine = TaptionBackupEngine(
            store: store, destination: TaptionLocalFolderBackupDestination(directory: backups),
            calendar: calendar, configuration: configuration
        )
        let archive = try SensorReadingArchive(fileURL: root.appendingPathComponent("readings.jsonl"), store: store)
        let model = AppModel(
            repository: TaptionStoreRepository(store: store),
            sensorService: AppleSensorDataService(archive: archive),
            cloudSyncService: nil,
            securityService: service(store: vaultStore),
            backupEngine: engine,
            rawDeviceDataArchive: try RawDeviceDataDayArchive(store: store),
            dayDatabase: PlanDayDatabase(store: store)
        )
        model.isBootstrapped = true
        return (model, store)
    }
}
