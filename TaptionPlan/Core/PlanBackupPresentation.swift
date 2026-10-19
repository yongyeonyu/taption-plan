import Foundation

/// 데이터 보호 시트가 보여 주는 백업 진행·결과 값. 엔진 결과(`TaptionBackupEngine.*`)를 사용자 문구로 옮긴다.

enum PlanBackupActivity: Equatable, Sendable {
    case idle
    case backingUp(completed: Int, total: Int)
    case offloading
    case restoring(String)
    case deleting

    var isBusy: Bool { self != .idle }
}

struct PlanBackupItem: Equatable, Identifiable, Sendable {
    enum Kind: Equatable, Sendable {
        /// 새 파일을 올렸다 / 복원했다 / 로컬을 정리했다.
        case done
        /// 바뀐 데이터가 없어 그대로 뒀다.
        case unchanged
        /// 기존 백업을 지키려고 올리지 않았다(거부).
        case rejected
        /// 건너뛰었다(데이터 없음, 봉인, 검증 실패 등).
        case skipped
    }

    var id: String { name }
    /// `2026-10` 또는 설정 파일은 `settings`.
    var name: String
    var kind: Kind
    var detail: String
}

struct PlanBackupReport: Equatable, Sendable {
    enum Operation: Equatable, Sendable { case backup, offload, restore, deleteAll }

    var operation: Operation
    var finishedAt: Date
    var items: [PlanBackupItem]
    /// 작업이 중단된 이유(없으면 끝까지 실행됨).
    var failure: String?
    var summary: String

    var succeeded: Bool { failure == nil }
}

struct PlanBackupListingRow: Equatable, Identifiable, Sendable {
    var id: String { name }
    var name: String
    var scope: TaptionBackupScope
    var size: Int
    var rowCount: Int?
    var lastDataAt: Date?
    var createdAt: Date?
    /// 로컬에서 정리해 이 기기에는 없고 백업에만 있는 달.
    var isOffloaded: Bool
    /// 행 수·시각 같은 헤더 메타데이터를 채웠는지(비밀번호를 넣은 뒤에만 true).
    var metadataShown: Bool
    /// 메타데이터를 보여 준 상태에서 헤더를 읽었는지(깨졌거나 아직 내려받지 못한 파일은 false).
    var isReadable: Bool
}

enum PlanBackupPresenter {
    private static func text(_ korean: String, _ english: String) -> String {
        AppLanguagePreference.text(korean: korean, english: english)
    }

    static func name(of scope: TaptionBackupScope) -> String { scope.key }

    static func item(for result: TaptionBackupEngine.BackupResult) -> PlanBackupItem {
        let name = name(of: result.scope)
        let rows = result.header?.rowCount ?? 0
        switch result.outcome {
        case .written:
            return .init(name: name, kind: .done, detail: text("\(rows)행을 올렸습니다.", "Uploaded \(rows) rows."))
        case .unchanged:
            return .init(name: name, kind: .unchanged, detail: text("바뀐 데이터가 없어 그대로 둡니다.", "No changes, left as is."))
        case .keptExisting(let reason):
            return .init(name: name, kind: .rejected, detail: keepDetail(reason))
        case .skippedSealed:
            return .init(
                name: name, kind: .skipped,
                detail: text("이 기기에서 정리된 달이라 기존 백업을 건드리지 않았습니다.", "This month was cleared from this device; the backup was not touched.")
            )
        case .skippedNoData:
            return .init(
                name: name, kind: .skipped,
                detail: text("이 기기에 데이터가 없어 기존 백업을 건드리지 않았습니다.", "No data on this device; the existing backup was not touched.")
            )
        case .failed(let message):
            return .init(name: name, kind: .rejected, detail: message)
        }
    }

    static func keepDetail(_ reason: TaptionBackupEngine.KeepReason) -> String {
        switch reason {
        case .fewerRows(let existing, let new):
            text(
                "기존 백업(\(existing)행)보다 이 기기의 행(\(new))이 적어 기존 백업을 지켰습니다.",
                "This device has fewer rows (\(new)) than the existing backup (\(existing)), so the backup was kept."
            )
        case .earlierLastTimestamp:
            text(
                "이 기기의 마지막 기록 시각이 기존 백업보다 앞서 기존 백업을 지켰습니다.",
                "The last record on this device is older than the backup's, so the backup was kept."
            )
        case .olderRecordUpdates:
            text(
                "이 기기 기록의 수정 시각이 기존 백업보다 오래되어 기존 백업을 지켰습니다.",
                "Records on this device were edited earlier than the backup's, so the backup was kept."
            )
        case .existingUnreadable:
            text(
                "기존 백업 파일을 읽을 수 없어 덮어쓰지 않았습니다.",
                "The existing backup file could not be read, so it was not overwritten."
            )
        case .existingCorrupted:
            text(
                "기존 백업 파일이 손상되었고 이 기기에 그 내용이 모두 없어 덮어쓰지 않았습니다.",
                "The existing backup is damaged and this device does not hold all of it, so it was not overwritten."
            )
        case .staleAfterDataWipe:
            text(
                "전체 데이터 삭제 전에 만든 백업이라 합치지도 덮어쓰지도 않았습니다. 복원하거나 백업을 삭제하세요.",
                "This backup predates a full data deletion, so it was neither merged nor overwritten. Restore it or delete the backups."
            )
        }
    }

    static func item(for result: TaptionBackupEngine.OffloadResult) -> PlanBackupItem {
        let name = result.month.key
        switch result.outcome {
        case .sealed(let readings, let records):
            return .init(
                name: name, kind: .done,
                detail: text(
                    "백업을 다시 확인한 뒤 이 기기에서 정리했습니다(센서 \(readings)행, 기록 \(records)행).",
                    "Verified the backup and cleared it from this device (\(readings) sensor rows, \(records) records)."
                )
            )
        case .skipped(let message):
            return .init(name: name, kind: .skipped, detail: skipDetail(message))
        }
    }

    /// 엔진의 건너뛴 이유(한국어 문장)를 사용자 문구로 옮긴다. 알 수 없는 이유는 일반 문구로 대신한다.
    static func skipDetail(_ message: String) -> String {
        if message.contains("백업이 없거나") {
            return text("백업 파일이 없거나 읽을 수 없어 지우지 않았습니다.", "No readable backup file, so nothing was removed.")
        }
        if message.contains("달이 끝나기 전에") {
            return text("달이 끝나기 전에 만든 백업이라 지우지 않았습니다. 지금 백업을 다시 하세요.", "The backup was made before the month ended, so nothing was removed. Back up again.")
        }
        if message.contains("내용이 로컬과 달라") {
            return text("백업 내용이 이 기기와 달라 지우지 않았습니다. 지금 백업을 다시 하세요.", "The backup differs from this device, so nothing was removed. Back up again.")
        }
        if message.contains("새 행이 들어와") {
            return text("확인하는 동안 새 데이터가 들어와 지우지 않았습니다.", "New data arrived during verification, so nothing was removed.")
        }
        if message.contains("검증 실패") {
            return text("백업 확인에 실패해(비밀번호가 다르거나 파일이 손상됨) 지우지 않았습니다.", "Backup verification failed (wrong password or damaged file), so nothing was removed.")
        }
        return text("안전을 위해 지우지 않았습니다.", "Not removed, to be safe.")
    }

    static func message(for error: Error) -> String {
        if let error = error as? TaptionBackupError { return error.userMessage }
        if let error = error as? PlanSecurityError { return error.localizedDescription() }
        if error is CancellationError { return text("작업이 취소되었습니다.", "The operation was cancelled.") }
        return error.localizedDescription
    }
}

extension TaptionBackupError {
    var userMessage: String {
        func text(_ korean: String, _ english: String) -> String {
            AppLanguagePreference.text(korean: korean, english: english)
        }
        switch self {
        case .emptyPassword:
            return text("비밀번호를 입력해 주세요.", "Enter your password.")
        case .wrongPassword:
            return text(
                "이 백업을 만들 때 쓴 비밀번호와 다릅니다. 비밀번호를 바꾸기 전에 만든 백업은 이전 비밀번호로 열립니다.",
                "This is not the password used for this backup. Backups made before a password change open with the old password."
            )
        case .authenticationFailed, .checksumMismatch, .notABackup, .malformed, .unsupportedVersion:
            return text("백업 파일이 손상되었거나 지원하지 않는 형식입니다.", "The backup file is damaged or in an unsupported format.")
        case .keyDerivationFailed:
            return text("암호 키를 만들지 못했습니다.", "Could not derive the encryption key.")
        case .fileMissing:
            return text("백업 파일을 찾지 못했습니다.", "The backup file was not found.")
        case .destinationUnavailable:
            return text(
                "iCloud Drive를 사용할 수 없습니다. iCloud 로그인과 설정의 iCloud Drive를 확인해 주세요.",
                "iCloud Drive is unavailable. Check that you are signed in to iCloud and iCloud Drive is on."
            )
        case .verificationFailed:
            return text(
                "올린 파일을 다시 확인하지 못했습니다. 기존 백업은 그대로입니다.",
                "The uploaded file could not be verified. The existing backup is unchanged."
            )
        case .passwordDiffersFromExistingBackup:
            return text(
                "기존 백업을 만들 때 쓴 비밀번호와 달라 올리지 않았습니다. 비밀번호를 다시 확인해 주세요.",
                "This password differs from the one used for the existing backup, so nothing was uploaded. Check your password."
            )
        case .conflictingVersions:
            return text(
                "iCloud에 같은 백업의 충돌 버전이 있어 건드리지 않았습니다. 다른 기기의 백업을 정리해 주세요.",
                "iCloud has conflicting versions of this backup, so it was left untouched. Resolve them on your other devices."
            )
        }
    }
}
