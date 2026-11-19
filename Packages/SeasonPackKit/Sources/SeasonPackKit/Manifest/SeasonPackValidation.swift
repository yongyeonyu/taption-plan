import CryptoKit
import Foundation

public enum SeasonPackLimits {
    public static let packBytes = 8 * 1024 * 1024
    public static let imageBytes = 400 * 1024
    public static let audioBytes = 2 * 1024 * 1024
    public static let filesPerPack = 40
    /// 저데이터·셀룰러에서는 이보다 큰 팩을 받지 않는다.
    public static let cellularBytes = 2 * 1024 * 1024
    public static let storedVersions = 3
    public static let storedBytes = 32 * 1024 * 1024
}

public enum SeasonPackValidationResult: Sendable, Equatable {
    case valid
    /// 이 빌드보다 새 팩. 받지 않고 「나중에」로 둔다.
    case deferred
    case invalid(String)

    public var isValid: Bool { self == .valid }
}

public enum SeasonPackValidation {
    public static let reservedIDs: Set<String> = ["memos"]

    /// `files`는 팩 폴더 기준 상대 경로 → 파일 내용(매니페스트 자신은 넣지 않는다).
    public static func validate(_ manifest: SeasonPackManifest, files: [String: Data], appBuild: Int?) -> SeasonPackValidationResult {
        if manifest.format != SeasonPackManifest.format { return .invalid("format") }
        if manifest.schema != SeasonPackManifest.supportedSchema { return .invalid("schema") }
        if !isKeyName(manifest.id) || reservedIDs.contains(manifest.id) { return .invalid("id") }
        if manifest.version < 1 { return .invalid("version") }
        if let required = manifest.requiresAppBuild, let appBuild, required > appBuild { return .deferred }
        if manifest.event.windows.isEmpty { return .invalid("windows") }
        if let reason = windowProblem(manifest.event.windows) { return .invalid(reason) }
        if manifest.assets.count > SeasonPackLimits.filesPerPack { return .invalid("files") }

        var total = 0
        var ids = Set<String>()
        for asset in manifest.assets {
            guard isRelativePath(asset.path), ids.insert(asset.id).inserted else { return .invalid("asset \(asset.id)") }
            guard let data = files[asset.path] else { return .invalid("missing \(asset.path)") }
            guard data.count == asset.bytes else { return .invalid("bytes \(asset.path)") }
            let limit = asset.isAudio ? SeasonPackLimits.audioBytes : (asset.isImage ? SeasonPackLimits.imageBytes : SeasonPackLimits.audioBytes)
            if data.count > limit { return .invalid("too large \(asset.path)") }
            if sha256Hex(data) != asset.sha256.lowercased() { return .invalid("sha256 \(asset.path)") }
            total += data.count
        }
        if total > SeasonPackLimits.packBytes { return .invalid("pack too large") }
        if let reason = referenceProblem(manifest, assetIDs: ids) { return .invalid(reason) }
        return .valid
    }

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// R2 키 한 칸과 같은 모양(`^[A-Za-z0-9][A-Za-z0-9._-]*$`, 40자 이하).
    public static func isKeyName(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty, bytes.count <= 40, isAlnum(bytes[0]) else { return false }
        return bytes.allSatisfy { isAlnum($0) || $0 == 46 || $0 == 95 || $0 == 45 }
    }

    private static func isAlnum(_ b: UInt8) -> Bool { (48...57).contains(b) || (65...90).contains(b) || (97...122).contains(b) }

    /// 소문자·숫자·`.`·`-`·`_`, 칸은 `/`로 최대 3칸, `.`으로 시작하는 칸 금지.
    public static func isRelativePath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count), path.count <= 120 else { return false }
        return parts.allSatisfy { part in
            guard let first = part.unicodeScalars.first, first != "." else { return false }
            return part.unicodeScalars.allSatisfy { ("a"..."z").contains(Character($0)) || ("0"..."9").contains(Character($0)) || "._-".unicodeScalars.contains($0) }
        }
    }

    private static func referenceProblem(_ manifest: SeasonPackManifest, assetIDs: Set<String>) -> String? {
        var refs: [String] = []
        if let house = manifest.slots?.house {
            refs += [house.base] + [house.lit, house.glow].compactMap { $0 } + (house.stages ?? []).map(\.image)
        }
        if let accessory = manifest.slots?.accessory {
            refs += [accessory.hat, accessory.scarf, accessory.ribbon].compactMap { $0?.asset }
        }
        refs += (manifest.slots?.outfit ?? [:]).values.flatMap { $0.map(\.asset) }
        refs += (manifest.slots?.shareCard?.house).map { [$0] } ?? []
        refs += (manifest.actors ?? []).flatMap { [$0.image] + ($0.tap?.burst?.images ?? []) }
        refs += (manifest.audio ?? []).map(\.asset)
        refs += (manifest.menuIcons ?? []).map(\.icon)
        if let missing = refs.first(where: { !assetIDs.contains($0) }) { return "unknown asset \(missing)" }
        let audioIDs = Set((manifest.audio ?? []).map(\.id))
        if (manifest.lyrics ?? []).contains(where: { !audioIDs.contains($0.audio) }) { return "unknown audio" }
        return nil
    }

    /// 같은 팩 안의 창이 겹치면 어느 쪽이 켜질지 모호하다. 날짜(월·일)만 비교하고, 규칙 창은 건너뛴다.
    private static func windowProblem(_ windows: [SeasonPackManifest.Window]) -> String? {
        struct Span { var from: Int; var to: Int; var year: Int? }
        func ordinal(_ md: SeasonPackManifest.Window.MonthDay) -> Int { md.month * 100 + md.day }
        var spans: [Span] = []
        for window in windows where window.rule == nil {
            guard let from = window.from, let to = window.to, (1...12).contains(from.month), (1...31).contains(from.day),
                  (1...12).contains(to.month), (1...31).contains(to.day) else { return "window" }
            if from <= to {
                spans.append(Span(from: ordinal(from), to: ordinal(to), year: window.year))
            } else {
                spans.append(Span(from: ordinal(from), to: 1231, year: window.year))
                spans.append(Span(from: 101, to: ordinal(to), year: window.year))
            }
        }
        for i in spans.indices {
            for j in spans.indices where j > i {
                let sameYear = spans[i].year == nil || spans[j].year == nil || spans[i].year == spans[j].year
                if sameYear, spans[i].from <= spans[j].to, spans[j].from <= spans[i].to { return "windows overlap" }
            }
        }
        return nil
    }
}
