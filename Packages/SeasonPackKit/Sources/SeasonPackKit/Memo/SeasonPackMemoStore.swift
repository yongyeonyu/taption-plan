import Foundation
import Synchronization

public struct SeasonPackMemo: Codable, Sendable, Equatable {
    public var text: String
    public var updatedAt: Date
}

public enum SeasonPackMemoError: Error, Sendable, Equatable {
    case readOnly
    case badName
    case io
}

/// `memos/<packId>/<itemId>.json`. 백업·스냅숏에 넣지 않고(백업 제외 표시), 팩 설치 폴더와 같은 뿌리 아래 둔다.
/// `readOnlyAfter`(`yyyy-MM-ddTHH:mm`, 그 분이 끝난 뒤)가 지나면 입력·저장·지우기를 막는다.
public final class SeasonPackMemoStore: Sendable {
    public let directory: URL
    private let lock = Mutex(())

    public init(directory: URL) { self.directory = directory }

    public static func isReadOnly(readOnlyAfter: String?, now: Date, calendar: Calendar = .current) -> Bool {
        guard let readOnlyAfter, let limit = SeasonPackDateParsing.localDateTime(readOnlyAfter, calendar: calendar) else { return false }
        return now >= limit.addingTimeInterval(60)
    }

    public func load(packID: String, itemID: String) -> SeasonPackMemo? {
        guard let url = fileURL(packID, itemID) else { return nil }
        return lock.withLock { _ in (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(SeasonPackMemo.self, from: $0) } }
    }

    @discardableResult
    public func save(_ text: String, packID: String, itemID: String, maxLength: Int?, readOnlyAfter: String?, now: Date = Date(), calendar: Calendar = .current) throws -> SeasonPackMemo {
        guard let url = fileURL(packID, itemID) else { throw SeasonPackMemoError.badName }
        if Self.isReadOnly(readOnlyAfter: readOnlyAfter, now: now, calendar: calendar) { throw SeasonPackMemoError.readOnly }
        let limit = maxLength.map { max(0, min($0, 2000)) } ?? 500
        let memo = SeasonPackMemo(text: String(text.prefix(limit)), updatedAt: now)
        return try lock.withLock { _ in
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                SeasonPackStore.excludeFromBackup(directory)
                SeasonPackStore.excludeFromBackup(url.deletingLastPathComponent())
                try JSONEncoder().encode(memo).write(to: url, options: .atomic)
            } catch { throw SeasonPackMemoError.io }
            return memo
        }
    }

    public func delete(packID: String, itemID: String, readOnlyAfter: String?, now: Date = Date(), calendar: Calendar = .current) throws {
        guard let url = fileURL(packID, itemID) else { throw SeasonPackMemoError.badName }
        if Self.isReadOnly(readOnlyAfter: readOnlyAfter, now: now, calendar: calendar) { throw SeasonPackMemoError.readOnly }
        lock.withLock { _ in try? FileManager.default.removeItem(at: url) }
    }

    /// 메모 첫 줄(말풍선·글자 칸용). 길면 말줄임.
    public func firstLine(packID: String, itemID: String, limit: Int = 24) -> String? {
        guard let line = load(packID: packID, itemID: itemID)?.text.split(whereSeparator: \.isNewline).first.map(String.init), !line.isEmpty else { return nil }
        return line.count > limit ? String(line.prefix(limit)) + "…" : line
    }

    public func removeAll() { lock.withLock { _ in try? FileManager.default.removeItem(at: directory) } }

    private func fileURL(_ packID: String, _ itemID: String) -> URL? {
        guard SeasonPackValidation.isKeyName(packID), SeasonPackValidation.isKeyName(itemID) else { return nil }
        return directory.appendingPathComponent(packID, isDirectory: true).appendingPathComponent("\(itemID).json")
    }
}
