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
    func fetch(name: String) async throws -> URL
    /// `localFile`의 내용으로 `name`을 원자적으로 만들거나 교체한다. 실패하면 기존 파일은 그대로다.
    func replace(name: String, with localFile: URL) async throws
    func remove(name: String) async throws
}

/// 폴더 하나를 목적지로 쓴다. 같은 폴더에 임시 이름으로 복사한 뒤 한 번에 바꿔 놓는다.
struct TaptionLocalFolderBackupDestination: TaptionBackupDestination {
    let directory: URL

    init(directory: URL) {
        self.directory = directory
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
        let staging = directory.appendingPathComponent(".\(name).uploading-\(UUID().uuidString)", isDirectory: false)
        do {
            try fileManager.copyItem(at: localFile, to: staging)
            if fileManager.fileExists(atPath: target.path) {
                _ = try fileManager.replaceItemAt(target, withItemAt: staging)
            } else {
                try fileManager.moveItem(at: staging, to: target)
            }
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    func remove(name: String) async throws {
        let url = directory.appendingPathComponent(name, isDirectory: false)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}

/// iCloud Drive 목적지. 앱의 ubiquity 컨테이너 안 `Documents/TaptionBackup` 폴더에 파일을 복사한다.
///
/// **기기에서만 동작한다.** `FileManager.url(forUbiquityContainerIdentifier:)`는 iCloud 로그인과
/// iCloud Documents entitlement(`com.apple.developer.icloud-container-identifiers`,
/// `com.apple.developer.ubiquity-container-identifiers`)가 있는 서명된 앱에서만 주소를 돌려주며,
/// 시뮬레이터·테스트 호스트·entitlement 없는 빌드에서는 nil이라 `destinationUnavailable`을 던진다.
/// 이 저장소의 entitlement는 아직 설정하지 않았고, 이 구현은 실기기에서 검증하지 못했다.
/// 읽기 전에 `startDownloadingUbiquitousItem`으로 내려받고, 쓰기·삭제는 `NSFileCoordinator`를 거친다.
struct TaptionICloudDriveBackupDestination: TaptionBackupDestination {
    let containerIdentifier: String?
    let folderName: String
    /// 내려받기를 기다리는 최대 시간(초).
    let downloadTimeout: TimeInterval

    init(containerIdentifier: String? = nil, folderName: String = "TaptionBackup", downloadTimeout: TimeInterval = 120) {
        self.containerIdentifier = containerIdentifier
        self.folderName = folderName
        self.downloadTimeout = downloadTimeout
    }

    /// 컨테이너 주소 조회는 오래 걸릴 수 있어 메인 스레드에서 부르지 않는다.
    private func folder() async throws -> TaptionLocalFolderBackupDestination {
        let identifier = containerIdentifier
        let name = folderName
        let container: URL? = await Task.detached {
            FileManager.default.url(forUbiquityContainerIdentifier: identifier)
        }.value
        guard let container else {
            throw TaptionBackupError.destinationUnavailable("iCloud Drive container is unavailable")
        }
        return TaptionLocalFolderBackupDestination(
            directory: container.appendingPathComponent("Documents", isDirectory: true)
                .appendingPathComponent(name, isDirectory: true)
        )
    }

    func list() async throws -> [TaptionBackupFileInfo] {
        try await folder().list()
    }

    func fetch(name: String) async throws -> URL {
        let url = try await folder().fetch(name: name)
        try FileManager.default.startDownloadingUbiquitousItem(at: url)
        let deadline = Date().addingTimeInterval(downloadTimeout)
        while Date() < deadline {
            let status = try url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
                .ubiquitousItemDownloadingStatus
            if status == nil || status == .current { return url }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw TaptionBackupError.destinationUnavailable("download timed out: \(name)")
    }

    func replace(name: String, with localFile: URL) async throws {
        let destination = try await folder()
        let target = destination.directory.appendingPathComponent(name, isDirectory: false)
        try FileManager.default.createDirectory(at: destination.directory, withIntermediateDirectories: true)
        // 로컬 폴더 구현이 임시 이름에 복사해 바꿔 놓는다. 최종 이름 쓰기는 조정자를 거쳐 iCloud 데몬과 겹치지 않게 한다.
        let staging = destination.directory.appendingPathComponent(".\(name).uploading-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.copyItem(at: localFile, to: staging)
        try Self.coordinatedReplace(target: target, with: staging)
    }

    func remove(name: String) async throws {
        let destination = try await folder()
        let target = destination.directory.appendingPathComponent(name, isDirectory: false)
        guard FileManager.default.fileExists(atPath: target.path) else { return }
        try Self.coordinated(target, options: .forDeleting) { url in
            try FileManager.default.removeItem(at: url)
        }
    }

    private static func coordinatedReplace(target: URL, with staging: URL) throws {
        try coordinated(target, options: .forReplacing) { url in
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: staging)
            } else {
                try FileManager.default.moveItem(at: staging, to: url)
            }
        }
    }

    private static func coordinated(
        _ url: URL, options: NSFileCoordinator.WritingOptions, _ body: (URL) throws -> Void
    ) throws {
        var coordinationError: NSError?
        var bodyError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: url, options: options, error: &coordinationError
        ) { coordinatedURL in
            do { try body(coordinatedURL) } catch { bodyError = error }
        }
        if let error = coordinationError ?? bodyError.map({ $0 as NSError }) { throw error }
    }
}
