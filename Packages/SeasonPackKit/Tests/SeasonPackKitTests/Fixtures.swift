import Foundation
import Synchronization
@testable import SeasonPackKit

enum Fixture {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return calendar
    }()

    static func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    /// 매일 16:50 일몰·07:40 일출(가짜 값).
    static let sun: SeasonPackSunProvider = { day in
        let calendar = Fixture.calendar
        return SeasonPackSunTimes(
            sunrise: calendar.date(bySettingHour: 7, minute: 40, second: 0, of: day),
            sunset: calendar.date(bySettingHour: 16, minute: 50, second: 0, of: day)
        )
    }

    static var windows: SeasonPackWindows { SeasonPackWindows(calendar: calendar, sun: sun) }

    static func window(_ fm: Int, _ fd: Int, _ tm: Int, _ td: Int, year: Int? = nil, fromTime: String? = nil, toTime: String? = nil) -> [String: Any] {
        var window: [String: Any] = ["from": ["month": fm, "day": fd], "to": ["month": tm, "day": td]]
        if let year { window["year"] = year }
        if let fromTime { window["fromTime"] = fromTime }
        if let toTime { window["toTime"] = toTime }
        return window
    }

    /// 자산 하나(`a.png`)만 든 가짜 팩의 매니페스트 바이트와 파일.
    static func pack(
        id: String = "demo", version: Int = 1, windows: [[String: Any]]? = nil, requiresAppBuild: Int? = nil,
        priority: Int? = nil, extra: [String: Any] = [:], fileBytes: Data = Data("png-bytes".utf8)
    ) -> (manifest: Data, files: [String: Data]) {
        var root: [String: Any] = [
            "format": "bokki-season-pack", "schema": 1, "id": id, "version": version,
            "event": ["id": id, "windows": windows ?? [window(12, 19, 12, 30)]],
            "assets": [["id": "img.a", "path": "a.png", "sha256": SeasonPackValidation.sha256Hex(fileBytes), "bytes": fileBytes.count, "kind": "image"]],
        ]
        if let requiresAppBuild { root["requiresAppBuild"] = requiresAppBuild }
        if let priority { root["priority"] = priority }
        for (key, value) in extra { root[key] = value }
        return (try! JSONSerialization.data(withJSONObject: root), ["a.png": fileBytes])
    }

    static func manifest(_ data: Data) -> SeasonPackManifest { try! JSONDecoder().decode(SeasonPackManifest.self, from: data) }

    static func tempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SeasonPackKitTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func suite() -> String { "SeasonPackKitTests.\(UUID().uuidString)" }

    /// 시험이 쓰는 사이트 팩(번들 시드)을 이름으로 꺼낸다.
    static func seedPack(_ id: String) -> SeasonPack {
        SeasonPackSeed.bundledPacks(appBuild: 1000).first { $0.id == id }!
    }
}

/// 시계 시험용 가짜 시간(기기 시각과 단조 시간을 따로 움직인다).
final class TestTime: Sendable {
    private let state: Mutex<(device: Date, mono: TimeInterval)>
    init(device: Date, mono: TimeInterval = 1000) { state = Mutex((device, mono)) }
    var device: Date { state.withLock { $0.device } }
    var mono: TimeInterval { state.withLock { $0.mono } }
    /// 실제로 시간이 흐른 것.
    func advance(_ seconds: TimeInterval) { state.withLock { $0.device.addTimeInterval(seconds); $0.mono += seconds } }
    /// 사용자가 기기 시각만 바꾼 것(단조 시간은 그대로).
    func setDevice(_ date: Date) { state.withLock { $0.device = date } }
}

final class MemoryClockStorage: SeasonPackClockStorage {
    private let state = Mutex(SeasonPackClockState())
    func load() -> SeasonPackClockState { state.withLock { $0 } }
    func save(_ new: SeasonPackClockState) { state.withLock { $0 = new } }
}

final class FakeHost: SeasonPackHost {
    private let clockDate: Mutex<Date>
    let languageCode: String
    let characterID: String
    var homeCoordinate: (latitude: Double, longitude: Double)? { (0, 0) }
    var buildNumber: Int? { 1000 }
    private let presented = Mutex<[String]>([])
    var presentedAnnouncements: [String] { presented.withLock { $0 } }

    init(now: Date, language: String = "ko", character: String = "white") {
        clockDate = Mutex(now); languageCode = language; characterID = character
    }

    func now() -> Date { clockDate.withLock { $0 } }
    func set(_ date: Date) { clockDate.withLock { $0 = date } }
    func sunEvents(on day: Date) -> (sunrise: Date?, sunset: Date?) {
        let sun = Fixture.sun(day)
        return (sun.sunrise, sun.sunset)
    }
    @MainActor func presentAnnouncement(id: String) -> Bool { presented.withLock { $0.append(id) }; return true }
    @MainActor func reportDemoState(_ state: SeasonPackDemoState) {}
}
