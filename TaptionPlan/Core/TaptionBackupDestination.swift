import Foundation

struct TaptionBackupFileInfo: Equatable, Sendable {
    var name: String
    var size: Int
    var modifiedAt: Date
}

/// 백업 파일을 두는 곳. 월 파일 하나를 이름으로 다루는 파일 복사 수준의 추상화다.
protocol TaptionBackupDestination: Sendable {
    /// `.taptionbackup` 파일 목록(업로드 중인 임시 파일은 제외).
    func list() async throws -> [TaptionBackupFileInfo]
    /// 읽을 수 있는 로컬 파일 주소를 돌려준다. 내려받아야 하면 받은 뒤에 돌려준다.
    /// 다 쓰면 `release(fetched:)`로 돌려줘야 한다(사본을 만드는 목적지가 정리할 수 있게).
    func fetch(name: String) async throws -> URL
    /// `fetch`가 돌려준 주소를 다 썼다고 알린다. 목적지가 만든 임시 사본이면 지운다. 기본 구현은 아무것도 하지 않는다.
    func release(fetched: URL) async
    /// 파일의 앞 `length`바이트(헤더 영역). 전체를 내려받거나 복사하지 않고 비밀번호 없이 헤더만 볼 때 쓴다.
    func fetchPrefix(name: String, length: Int) async throws -> Data
    /// `localFile`의 내용으로 `name`을 원자적으로 만들거나 교체한다. 실패하면 기존 파일은 그대로다.
    func replace(name: String, with localFile: URL) async throws
    func remove(name: String) async throws
    /// 이전 실행이 남긴 업로드 임시 파일을 치운다. 기본 구현은 아무것도 하지 않는다.
    func cleanupStaleUploads() async
}

extension TaptionBackupDestination {
    func release(fetched: URL) async {}
    func cleanupStaleUploads() async {}

    func fetchPrefix(name: String, length: Int) async throws -> Data {
        let url = try await fetch(name: name)
        let data: Data
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            data = try handle.read(upToCount: length) ?? Data()
        } catch {
            await release(fetched: url)
            throw error
        }
        await release(fetched: url)
        return data
    }
}

/// 파일·폴더 내용을 디스크에 실제로 내려 쓴다(`F_FULLFSYNC`, 안 되면 `fsync`). 크래시·전원 차단 뒤에도
/// 교체가 끝난 파일이 온전하도록 교체 전에는 파일을, 교체 뒤에는 폴더를 동기화한다.
enum TaptionBackupDurability {
    static func sync(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw TaptionBackupError.destinationUnavailable("cannot open \(url.lastPathComponent) to sync") }
        defer { close(descriptor) }
        if fcntl(descriptor, F_FULLFSYNC) != 0, fsync(descriptor) != 0 {
            throw TaptionBackupError.destinationUnavailable("cannot sync \(url.lastPathComponent)")
        }
    }
}

/// 업로드 임시 파일을 목적지 폴더 **밖**에 만든다. 같은 폴더(특히 iCloud 폴더)에 두면 크래시 때 숨은 파일이
/// 남아 기기 사이로 동기화되고, 목록·용량에도 섞인다. 가능하면 대상과 같은 볼륨의 항목 교체 폴더를 쓴다.
enum TaptionBackupStaging {
    struct Staged {
        var file: URL
        /// 정리할 때 지울 것(파일이 든 폴더 또는 파일 자신).
        var cleanup: URL
    }

    static func make(name: String, near target: URL, in override: URL?) throws -> Staged {
        let fileManager = FileManager.default
        let leaf = ".\(name).uploading-\(UUID().uuidString)"
        if let override {
            try fileManager.createDirectory(at: override, withIntermediateDirectories: true)
            let file = override.appendingPathComponent(leaf, isDirectory: false)
            return Staged(file: file, cleanup: file)
        }
        if let folder = try? fileManager.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target, create: true
        ) {
            return Staged(file: folder.appendingPathComponent(leaf, isDirectory: false), cleanup: folder)
        }
        let file = fileManager.temporaryDirectory.appendingPathComponent(leaf, isDirectory: false)
        return Staged(file: file, cleanup: file)
    }

    /// 이전 버전이 목적지 폴더 안에 남긴 `.<이름>.uploading-<UUID>`를 한 시간이 지난 것만 치운다
    /// (다른 기기가 지금 올리는 중일 수 있어 최근 것은 건드리지 않는다).
    static func removeStaleUploads(in directory: URL, olderThan age: TimeInterval = 3_600, now: Date = Date()) {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name.hasPrefix(".") && name.contains(".uploading-") {
            let url = directory.appendingPathComponent(name)
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, now.timeIntervalSince(modified) < age { continue }
            try? fileManager.removeItem(at: url)
        }
    }
}

/// 폴더 하나를 목적지로 쓴다. 폴더 밖에서 복사해 둔 임시 파일을 한 번에 바꿔 놓는다.
struct TaptionLocalFolderBackupDestination: TaptionBackupDestination {
    let directory: URL
    /// 업로드 임시 파일을 둘 폴더. nil이면 대상과 같은 볼륨의 항목 교체 폴더(없으면 임시 폴더).
    let stagingDirectory: URL?
    /// 임시 파일을 쓴 뒤 교체하기 직전에 부른다(테스트에서 임시 파일 위치를 확인한다).
    let beforeCommit: (@Sendable (URL) throws -> Void)?

    init(directory: URL, stagingDirectory: URL? = nil, beforeCommit: (@Sendable (URL) throws -> Void)? = nil) {
        self.directory = directory
        self.stagingDirectory = stagingDirectory
        self.beforeCommit = beforeCommit
    }

    func list() async throws -> [TaptionBackupFileInfo] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)
            .filter { $0.pathExtension == TaptionBackupMonth.fileExtension && !$0.lastPathComponent.hasPrefix(".") }
            .map { url in
                let values = try url.resourceValues(forKeys: Set(keys))
                return TaptionBackupFileInfo(
                    name: url.lastPathComponent,
                    size: values.fileSize ?? 0,
                    modifiedAt: values.contentModificationDate ?? .distantPast
                )
            }
            .sorted { $0.name < $1.name }
    }

    func fetch(name: String) async throws -> URL {
        let url = directory.appendingPathComponent(name, isDirectory: false)
        guard FileManager.default.fileExists(atPath: url.path) else { throw TaptionBackupError.fileMissing(name) }
        return url
    }

    func replace(name: String, with localFile: URL) async throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent(name, isDirectory: false)
        let staged = try TaptionBackupStaging.make(name: name, near: target, in: stagingDirectory)
        defer { try? fileManager.removeItem(at: staged.cleanup) }
        try Self.commit(localFile, as: staged.file, to: target, beforeCommit: beforeCommit)
        try? TaptionBackupDurability.sync(directory)
    }

    /// 임시 파일에 복사·동기화한 뒤 대상과 바꾼다. 임시 파일이 대상 폴더 밖이어도 `replaceItemAt`이 알아서 처리한다.
    static func commit(
        _ localFile: URL, as staging: URL, to target: URL, beforeCommit: (@Sendable (URL) throws -> Void)?
    ) throws {
        let fileManager = FileManager.default
        try fileManager.copyItem(at: localFile, to: staging)
        try TaptionBackupDurability.sync(staging)
        try beforeCommit?(staging)
        if fileManager.fileExists(atPath: target.path) {
            _ = try fileManager.replaceItemAt(target, withItemAt: staging)
        } else {
            try fileManager.moveItem(at: staging, to: target)
        }
        try? TaptionBackupDurability.sync(target)
    }

    func remove(name: String) async throws {
        let url = directory.appendingPathComponent(name, isDirectory: false)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    func cleanupStaleUploads() async {
        TaptionBackupStaging.removeStaleUploads(in: directory)
    }
}

// MARK: iCloud Drive

enum TaptionUbiquityItemState: Equatable, Sendable {
    /// 파일이 없다(자리표시자만 있을 수 있다).
    case missing
    /// 내려받는 중이거나 아직 받지 않았다.
    case notDownloaded
    /// 로컬에 온전히 있다.
    case current
}

/// iCloud(ubiquity) 관련 시스템 호출을 감싼 얇은 층. 실제 구현은 기기에서만 동작하므로, 테스트는 같은 규약을 흉내 내는
/// 구현을 끼워 넣어 목적지 로직(자리표시자·다운로드 대기·충돌·조정 읽기)을 로컬 폴더에서 확인한다.
protocol TaptionUbiquityFileSystem: Sendable {
    func containerURL(identifier: String?) async -> URL?
    func state(of url: URL) -> TaptionUbiquityItemState
    func startDownloading(_ url: URL) throws
    func hasUnresolvedConflicts(at url: URL) -> Bool
    /// 파일 조정(NSFileCoordinator) 읽기로 `destination`에 복사한다.
    func coordinatedCopy(from url: URL, to destination: URL) throws
    /// 파일 조정 읽기로 앞부분만 읽는다.
    func coordinatedReadPrefix(of url: URL, length: Int) throws -> Data
    func coordinatedReplace(target: URL, with staging: URL) throws
    func coordinatedRemove(_ url: URL) throws
}

struct TaptionSystemUbiquityFileSystem: TaptionUbiquityFileSystem {
    func containerURL(identifier: String?) async -> URL? {
        await Task.detached { FileManager.default.url(forUbiquityContainerIdentifier: identifier) }.value
    }

    func state(of url: URL) -> TaptionUbiquityItemState {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        let status = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus
        // 상태를 알 수 없으면(ubiquity 항목이 아니거나 읽기 실패) 로컬 파일로 본다.
        return status == nil || status == .current ? .current : .notDownloaded
    }

    func startDownloading(_ url: URL) throws {
        try FileManager.default.startDownloadingUbiquitousItem(at: url)
    }

    func hasUnresolvedConflicts(at url: URL) -> Bool {
        if (try? url.resourceValues(forKeys: [.ubiquitousItemHasUnresolvedConflictsKey]))?
            .ubiquitousItemHasUnresolvedConflicts == true { return true }
        return !(NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []).isEmpty
    }

    func coordinatedCopy(from url: URL, to destination: URL) throws {
        try Self.coordinatedRead(url) { coordinated in
            try FileManager.default.copyItem(at: coordinated, to: destination)
        }
    }

    func coordinatedReadPrefix(of url: URL, length: Int) throws -> Data {
        var data = Data()
        try Self.coordinatedRead(url) { coordinated in
            let handle = try FileHandle(forReadingFrom: coordinated)
            defer { try? handle.close() }
            data = try handle.read(upToCount: length) ?? Data()
        }
        return data
    }

    func coordinatedReplace(target: URL, with staging: URL) throws {
        try Self.coordinatedWrite(target, options: .forReplacing) { url in
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: staging)
            } else {
                try FileManager.default.moveItem(at: staging, to: url)
            }
        }
    }

    func coordinatedRemove(_ url: URL) throws {
        try Self.coordinatedWrite(url, options: .forDeleting) { try FileManager.default.removeItem(at: $0) }
    }

    private static func coordinatedRead(_ url: URL, _ body: (URL) throws -> Void) throws {
        var coordinationError: NSError?
        var bodyError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(
            readingItemAt: url, options: [], error: &coordinationError
        ) { coordinated in
            do { try body(coordinated) } catch { bodyError = error }
        }
        if let error = coordinationError ?? bodyError.map({ $0 as NSError }) { throw error }
    }

    private static func coordinatedWrite(
        _ url: URL, options: NSFileCoordinator.WritingOptions, _ body: (URL) throws -> Void
    ) throws {
        var coordinationError: NSError?
        var bodyError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: url, options: options, error: &coordinationError
        ) { coordinated in
            do { try body(coordinated) } catch { bodyError = error }
        }
        if let error = coordinationError ?? bodyError.map({ $0 as NSError }) { throw error }
    }
}

/// iCloud Drive 목적지. 앱의 ubiquity 컨테이너 안 `Documents/TaptionBackup` 폴더에 파일을 둔다.
///
/// **실제 iCloud 연동은 기기에서만 동작한다.** `FileManager.url(forUbiquityContainerIdentifier:)`는 iCloud 로그인과
/// iCloud Documents entitlement(`com.apple.developer.icloud-container-identifiers`,
/// `com.apple.developer.ubiquity-container-identifiers`)가 있는 서명된 앱에서만 주소를 돌려주며,
/// 시뮬레이터·테스트 호스트·entitlement 없는 빌드에서는 nil이라 `destinationUnavailable`을 던진다.
/// 이 저장소의 entitlement는 아직 설정하지 않았고, 시스템 구현(`TaptionSystemUbiquityFileSystem`)은 실기기에서 검증하지 못했다.
/// 목적지 로직은 `TaptionUbiquityFileSystem` 뒤에 있어 흉내 구현으로 로컬 폴더에서 규약을 시험한다.
///
/// 규칙:
/// - 내려받지 않은 파일은 `.이름.icloud` 자리표시자로 보인다. 목록에는 실제 이름으로 올리고, 읽기 전에
///   `startDownloadingUbiquitousItem` 후 다운로드가 끝날 때까지(최대 `downloadTimeout`) 기다린다.
/// - 읽기는 파일 조정(`NSFileCoordinator`)을 거쳐 임시 사본에 복사한 뒤 그 사본을 돌려준다. 호출자는 사본으로 검증·복원을
///   한 번만 열고 `release(fetched:)`로 돌려준다.
/// - 풀리지 않은 충돌 버전(`ubiquitousItemHasUnresolvedConflicts`/`NSFileVersion`)이 있으면 읽기·쓰기를
///   `conflictingVersions`로 거부한다. 어느 버전이 맞는지 자동으로 고르지 않는다(사용자가 파일 앱에서 해결해야 한다).
struct TaptionICloudDriveBackupDestination: TaptionBackupDestination {
    let containerIdentifier: String?
    let folderName: String
    /// 내려받기를 기다리는 최대 시간(초).
    let downloadTimeout: TimeInterval
    let pollInterval: TimeInterval
    let fileSystem: any TaptionUbiquityFileSystem
    let temporaryDirectory: URL
    let stagingDirectory: URL?

    init(
        containerIdentifier: String? = nil, folderName: String = "TaptionBackup", downloadTimeout: TimeInterval = 120,
        pollInterval: TimeInterval = 0.5,
        fileSystem: any TaptionUbiquityFileSystem = TaptionSystemUbiquityFileSystem(),
        temporaryDirectory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("taption-icloud-fetch", isDirectory: true),
        stagingDirectory: URL? = nil
    ) {
        self.containerIdentifier = containerIdentifier
        self.folderName = folderName
        self.downloadTimeout = downloadTimeout
        self.pollInterval = pollInterval
        self.fileSystem = fileSystem
        self.temporaryDirectory = temporaryDirectory
        self.stagingDirectory = stagingDirectory
    }

    /// 컨테이너 주소 조회는 오래 걸릴 수 있어 메인 스레드에서 부르지 않는다.
    private func folder() async throws -> URL {
        guard let container = await fileSystem.containerURL(identifier: containerIdentifier) else {
            throw TaptionBackupError.destinationUnavailable("iCloud Drive container is unavailable")
        }
        return container.appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
    }

    static func placeholderName(for name: String) -> String { ".\(name).icloud" }

    static func realName(fromPlaceholder placeholder: String) -> String? {
        let suffix = ".icloud"
        guard placeholder.hasPrefix("."), placeholder.hasSuffix(suffix) else { return nil }
        let name = String(placeholder.dropFirst().dropLast(suffix.count))
        return name.hasSuffix("." + TaptionBackupMonth.fileExtension) ? name : nil
    }

    func list() async throws -> [TaptionBackupFileInfo] {
        let directory = try await folder()
        var infos = try await TaptionLocalFolderBackupDestination(directory: directory).list()
        // 내려받지 않은 파일은 실제 이름이 아닌 자리표시자로만 보인다.
        let known = Set(infos.map(\.name))
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for entry in names {
            guard let name = Self.realName(fromPlaceholder: entry), !known.contains(name) else { continue }
            let modified = (try? directory.appendingPathComponent(entry)
                .resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            infos.append(TaptionBackupFileInfo(name: name, size: 0, modifiedAt: modified ?? .distantPast))
        }
        return infos.sorted { $0.name < $1.name }
    }

    /// 내려받기를 끝낸 실제 파일 주소. 자리표시자만 있어도 받아 온다.
    private func downloadedURL(name: String, in directory: URL) async throws -> URL {
        let target = directory.appendingPathComponent(name, isDirectory: false)
        let placeholder = directory.appendingPathComponent(Self.placeholderName(for: name), isDirectory: false)
        guard fileSystem.state(of: target) != .missing || FileManager.default.fileExists(atPath: placeholder.path) else {
            throw TaptionBackupError.fileMissing(name)
        }
        if fileSystem.state(of: target) != .current {
            try fileSystem.startDownloading(target)
            let deadline = Date().addingTimeInterval(downloadTimeout)
            while fileSystem.state(of: target) != .current {
                guard Date() < deadline else { throw TaptionBackupError.destinationUnavailable("download timed out: \(name)") }
                try await Task.sleep(nanoseconds: UInt64(max(0.001, pollInterval) * 1_000_000_000))
            }
        }
        guard !fileSystem.hasUnresolvedConflicts(at: target) else { throw TaptionBackupError.conflictingVersions(name) }
        return target
    }

    func fetch(name: String) async throws -> URL {
        let directory = try await folder()
        let source = try await downloadedURL(name: name, in: directory)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        let copy = temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-\(name)", isDirectory: false)
        do {
            try fileSystem.coordinatedCopy(from: source, to: copy)
        } catch {
            try? FileManager.default.removeItem(at: copy)
            throw error
        }
        return copy
    }

    func release(fetched: URL) async {
        // 우리가 만든 임시 사본만 지운다.
        guard fetched.deletingLastPathComponent().standardizedFileURL == temporaryDirectory.standardizedFileURL else { return }
        try? FileManager.default.removeItem(at: fetched)
    }

    func fetchPrefix(name: String, length: Int) async throws -> Data {
        let directory = try await folder()
        let source = try await downloadedURL(name: name, in: directory)
        return try fileSystem.coordinatedReadPrefix(of: source, length: length)
    }

    func replace(name: String, with localFile: URL) async throws {
        let directory = try await folder()
        let target = directory.appendingPathComponent(name, isDirectory: false)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard !fileSystem.hasUnresolvedConflicts(at: target) else { throw TaptionBackupError.conflictingVersions(name) }
        let staged = try TaptionBackupStaging.make(name: name, near: target, in: stagingDirectory)
        defer { try? FileManager.default.removeItem(at: staged.cleanup) }
        try FileManager.default.copyItem(at: localFile, to: staged.file)
        try TaptionBackupDurability.sync(staged.file)
        try fileSystem.coordinatedReplace(target: target, with: staged.file)
    }

    func remove(name: String) async throws {
        let directory = try await folder()
        let target = directory.appendingPathComponent(name, isDirectory: false)
        if FileManager.default.fileExists(atPath: target.path) {
            try fileSystem.coordinatedRemove(target)
        }
        let placeholder = directory.appendingPathComponent(Self.placeholderName(for: name), isDirectory: false)
        if FileManager.default.fileExists(atPath: placeholder.path) {
            try fileSystem.coordinatedRemove(placeholder)
        }
    }

    func cleanupStaleUploads() async {
        guard let directory = try? await folder() else { return }
        TaptionBackupStaging.removeStaleUploads(in: directory)
    }
}
