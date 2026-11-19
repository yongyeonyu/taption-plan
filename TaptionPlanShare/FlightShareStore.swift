import Foundation

/// 공유 확장(「BOKKI Plan에 넣기」)과 앱이 App Group 컨테이너로 주고받는 보관함(FLT1119A01).
/// 두 타깃이 같은 파일을 컴파일하므로 Foundation만 쓴다. 확장은 글·링크·탑승권 파일을 여기에 두기만 하고, 앱이 열리거나 앞으로 올 때 읽어 간다.
/// 네트워크를 쓰지 않고, 보관 내용(이름·예약번호가 들 수 있다)을 로그로 남기지 않는다. 파일 시각 API는 쓰지 않는다(시각은 항목 안에 적는다).
enum FlightShareStore {
    static let groupIdentifier = "group.com.taption.plan"
    static let directoryName = "FlightShare"
    static let maximumEntries = 20
    static let maximumTextBytes = 20_000
    static let maximumPassBytes = 2_000_000
    /// 30일이 지난 항목은 읽을 때 버린다.
    static let lifetime: TimeInterval = 30 * 86_400

    struct Entry: Codable, Equatable, Identifiable {
        enum Kind: String, Codable { case text, pass }
        var id: String
        var kind: Kind
        var text: String?
        /// 탑승권 파일 이름(보관 폴더 안).
        var file: String?
        var at: Date
    }

    /// 보관 폴더. 시험은 `container`로 임시 폴더를 넘긴다.
    static func directory(container: URL? = nil) -> URL? {
        let base = container ?? FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier)
        guard let base else { return nil }
        let folder = base.appendingPathComponent(directoryName, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func indexURL(_ folder: URL) -> URL { folder.appendingPathComponent("inbox.json") }

    // MARK: 확장이 쓰는 쪽

    /// 글을 둔다. 비었거나 너무 길면 거절한다.
    @discardableResult
    static func enqueue(text: String, now: Date = .now, container: URL? = nil) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= maximumTextBytes, let folder = directory(container: container) else { return false }
        var entries = load(folder, now: now)
        // 같은 글을 연달아 공유해도 한 번만 둔다.
        if entries.contains(where: { $0.kind == .text && $0.text == trimmed }) { return true }
        entries.append(Entry(id: UUID().uuidString, kind: .text, text: trimmed, file: nil, at: now))
        return save(entries, folder: folder)
    }

    /// 탑승권(`.pkpass`) 파일을 둔다. 비었거나 너무 크면 거절한다.
    @discardableResult
    static func enqueue(passData: Data, now: Date = .now, container: URL? = nil) -> Bool {
        guard !passData.isEmpty, passData.count <= maximumPassBytes, let folder = directory(container: container) else { return false }
        let name = UUID().uuidString + ".pkpass"
        guard (try? passData.write(to: folder.appendingPathComponent(name), options: .atomic)) != nil else { return false }
        var entries = load(folder, now: now)
        entries.append(Entry(id: UUID().uuidString, kind: .pass, text: nil, file: name, at: now))
        return save(entries, folder: folder)
    }

    // MARK: 앱이 읽는 쪽

    /// 기다리는 항목(오래된 순). 30일이 지난 것은 지운다.
    static func pending(now: Date = .now, container: URL? = nil) -> [Entry] {
        guard let folder = directory(container: container) else { return [] }
        return load(folder, now: now)
    }

    static func passData(for entry: Entry, container: URL? = nil) -> Data? {
        guard entry.kind == .pass, let file = entry.file, !file.contains("/"), let folder = directory(container: container) else { return nil }
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(file)), data.count <= maximumPassBytes else { return nil }
        return data
    }

    /// 처리한 항목을 지운다(탑승권 파일도).
    static func remove(_ ids: [String], now: Date = .now, container: URL? = nil) {
        guard !ids.isEmpty, let folder = directory(container: container) else { return }
        let all = load(folder, now: now)
        for entry in all where ids.contains(entry.id) { if let file = entry.file, !file.contains("/") { try? FileManager.default.removeItem(at: folder.appendingPathComponent(file)) } }
        _ = save(all.filter { !ids.contains($0.id) }, folder: folder)
    }

    // MARK: 파일

    private static func load(_ folder: URL, now: Date) -> [Entry] {
        guard let data = try? Data(contentsOf: indexURL(folder)), let all = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        let fresh = all.filter { now.timeIntervalSince($0.at) < lifetime }
        // 만료된 탑승권 파일은 같이 지운다.
        for entry in all where !fresh.contains(entry) { if let file = entry.file, !file.contains("/") { try? FileManager.default.removeItem(at: folder.appendingPathComponent(file)) } }
        return fresh
    }

    private static func save(_ entries: [Entry], folder: URL) -> Bool {
        let kept = Array(entries.suffix(maximumEntries))
        for dropped in entries.dropLast(kept.count) { if let file = dropped.file, !file.contains("/") { try? FileManager.default.removeItem(at: folder.appendingPathComponent(file)) } }
        guard let data = try? JSONEncoder().encode(kept) else { return false }
        return (try? data.write(to: indexURL(folder), options: .atomic)) != nil
    }
}
