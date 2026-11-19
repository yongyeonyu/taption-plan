import Foundation

/// 앱에 함께 들어 있는 시드 팩. 서버가 아직 없어도 기간이 오면 뜨게 한다. 매니페스트·해시 규칙은 받은 팩과 같다.
public enum SeasonPackSeed {
    /// `Resources/seed/<id>/<version>/` 아래 팩. DEBUG 빌드에서는 표본 팩(`seed-debug`)도 함께 읽는다.
    public static func bundledPacks(appBuild: Int?) -> [SeasonPack] {
        var roots: [URL] = []
        if let url = Bundle.module.url(forResource: "seed", withExtension: nil) { roots.append(url) }
#if DEBUG
        if let url = Bundle.module.url(forResource: "seed-debug", withExtension: nil) { roots.append(url) }
#endif
        return roots.flatMap { packs(in: $0, appBuild: appBuild) }
    }

    public static func packs(in root: URL, appBuild: Int?) -> [SeasonPack] {
        let fm = FileManager.default
        let ids = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return ids.flatMap { idFolder in
            ((try? fm.contentsOfDirectory(at: idFolder, includingPropertiesForKeys: nil)) ?? [])
                .filter { Int($0.lastPathComponent) != nil }
                .compactMap { SeasonPackLoader.load(directory: $0, source: .seed, appBuild: appBuild) }
        }
    }

    /// 같은 id는 버전이 높은 쪽, 같으면 번들(시드)을 쓴다.
    public static func merge(installed: [SeasonPack], seeds: [SeasonPack]) -> [SeasonPack] {
        var best: [String: SeasonPack] = [:]
        for pack in seeds + installed {
            if let current = best[pack.id] {
                if pack.version > current.version { best[pack.id] = pack }
            } else {
                best[pack.id] = pack
            }
        }
        return best.values.sorted { $0.id < $1.id }
    }
}
