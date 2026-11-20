import Foundation

/// `packs/season/index.json` — 배급 목록. 작아서 앱이 먼저 읽는다.
public struct SeasonPackIndex: Codable, Sendable, Equatable {
    public static let format = "bokki-season-packs"

    /// 팩 하나를 묶은 `.bpack` 파일(HTTP Range·ETag를 지원하는 곳에 둔다). 크기와 SHA-256으로 받은 파일 전체를 검증한다.
    public struct Archive: Codable, Sendable, Equatable {
        public var key: String
        public var bytes: Int
        public var sha256: String
        public init(key: String, bytes: Int, sha256: String) { self.key = key; self.bytes = bytes; self.sha256 = sha256 }
    }

    /// 운영자가 정한 공개 기간 한 칸(절대 시각, 오프셋이 있는 ISO 8601). `[from, to)`.
    public struct Span: Codable, Sendable, Equatable {
        public var from: String
        public var to: String
        public init(from: String, to: String) { self.from = from; self.to = to }

        /// 읽지 못하거나 끝이 시작보다 이르면 nil(그 칸만 버린다).
        public var interval: DateInterval? {
            guard let start = Self.parse(from), let end = Self.parse(to), end > start else { return nil }
            return DateInterval(start: start, end: end)
        }

        static func parse(_ text: String) -> Date? {
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            if let date = plain.date(from: text) { return date }
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return fractional.date(from: text)
        }
    }

    public struct Entry: Codable, Sendable, Equatable {
        public var id: String
        public var version: Int
        /// 파일 하나로 받는 새 방식. 없으면 `manifest`로 파일을 하나씩 받는 예전 방식이다.
        public var archive: Archive?
        public var manifest: String?
        public var requiresAppBuild: Int?
        /// 매니페스트 `event.windows`의 사본: 받기 전에 「곧 쓸 팩인가」를 가려 먼 팩의 큰 파일을 받지 않는다.
        public var windows: [SeasonPackManifest.Window]?
        public var updatedAt: String?
        /// 운영 기간. 있으면 매니페스트 `windows` 대신 이 기간에만 켠다(빈 목록이면 꺼 둔다). 없으면 매니페스트 기간 그대로.
        /// 같은 팩을 여러 번 열 수 있다(칸을 여러 개 둔다). 기기에 같은 버전이 있으면 다시 받지 않는다.
        public var schedule: [Span]?
        public init(id: String, version: Int, archive: Archive? = nil, manifest: String? = nil, requiresAppBuild: Int? = nil, windows: [SeasonPackManifest.Window]? = nil, updatedAt: String? = nil,
                    schedule: [Span]? = nil) {
            self.id = id; self.version = version; self.archive = archive; self.manifest = manifest
            self.requiresAppBuild = requiresAppBuild; self.windows = windows; self.updatedAt = updatedAt; self.schedule = schedule
        }

        public var scheduleIntervals: [DateInterval]? { schedule.map { $0.compactMap(\.interval) } }
    }

    public var format: String
    public var schema: Int
    public var packs: [Entry]

    /// 운영 기간이 있는 팩만: id → 기간들. 앱은 이것을 저장해 두고 오프라인에서도 따른다.
    public var schedules: [String: [DateInterval]] {
        var out: [String: [DateInterval]] = [:]
        for entry in packs { if let spans = entry.scheduleIntervals { out[entry.id] = spans } }
        return out
    }

    /// 읽지 못하면 nil(받기를 그만두고 지금 팩을 그대로 쓴다).
    public static func decode(_ data: Data) -> SeasonPackIndex? {
        guard let index = try? JSONDecoder().decode(SeasonPackIndex.self, from: data),
              index.format == Self.format, index.schema == 1 else { return nil }
        return index
    }
}
