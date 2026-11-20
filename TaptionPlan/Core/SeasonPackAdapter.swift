import Foundation
import SeasonPackKit
import Synchronization
import TaptionAssistantKit
import UIKit
import TaptionPlanCore

/// `SeasonPackKit`이 아는 앱의 유일한 자리(SEA1119A01). 앱 타입을 아는 곳은 여기뿐이고, 패키지는 `SeasonPackHost`만 본다.
/// 집 좌표는 기기 안 일몰 계산에만 쓰이고 어디로도 보내지 않는다.
final class SeasonPackAdapter: SeasonPackHost {
    static let shared = SeasonPackAdapter()

    private struct State {
        var home: (latitude: Double, longitude: Double)?
        var character = "white"
    }

    private let state = Mutex(State())

    var languageCode: String { AnnouncementPolicy.languageCode() }
    var characterID: String { state.withLock { $0.character } }
    var homeCoordinate: (latitude: Double, longitude: Double)? { state.withLock { $0.home } }
    var buildNumber: Int? { AnnouncementPolicy.currentBuild() }

    func now() -> Date { Date() }

    /// `MapHomeAstronomy`(NOAA 태양 공식, 네트워크 없음)로 그날 일출·일몰을 푼다. 집이 없으면 둘 다 nil(트리는 켜지지 않는다).
    func sunEvents(on day: Date) -> (sunrise: Date?, sunset: Date?) {
        guard let home = homeCoordinate else { return (nil, nil) }
        let noon = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: day) ?? day
        let number = MapHomeAstronomy.solarDayNumber(at: noon, longitude: home.longitude)
        let solar = MapHomeAstronomy.solarDay(number: number, latitude: home.latitude, longitude: home.longitude)
        return (solar.sunrise, solar.sunset)
    }

    /// 팩의 공지를 기존 공지 시트로 한 번 보여 준다. 아직 받지 못한(목록에 없는) 공지면 false라 나중에 다시 시도한다.
    @MainActor func presentAnnouncement(id: String) -> Bool {
        guard AnnouncementService.shared.visible.contains(where: { $0.id == id }) else { return false }
        AnnouncementService.shared.requestSheet()
        return true
    }

    @MainActor func reportDemoState(_ state: SeasonPackDemoState) {}

    // MARK: 마운트

    /// 팩 파일(`.bpack`)을 이어 받는 백그라운드 `URLSession` 이름. 앱이 죽었다가 떠도 같은 이름으로 이어진다.
    static var backgroundSessionID: String { (Bundle.main.bundleIdentifier ?? "app") + ".seasonpack" }

    /// 앱 델리게이트 `handleEventsForBackgroundURLSession`에서 부른다(시스템이 앱을 깨워 받기 끝을 알릴 때).
    @MainActor static func handleBackgroundEvents(identifier: String, completion: @escaping @MainActor @Sendable () -> Void) {
        guard let engine = SeasonPackCenter.shared.backgroundEngine else { completion(); return }
        engine.handleEvents(forIdentifier: identifier, completion: completion)
    }

    static var storeRoot: URL {
        (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("SeasonPacks", isDirectory: true)
    }

    /// 홈이 열릴 때 한 번(그리고 설정이 바뀔 때) 현재 캐릭터·집 좌표를 알려 주고 센터를 설정한다.
    @MainActor static func sync(model: AppModel) {
        let home = model.settings.frequentPlaces.first { $0.kind == .home }?.point.map { ($0.latitude, $0.longitude) }
        shared.state.withLock {
            $0.home = home
            $0.character = ["white", "calico", "mackerel"].contains(model.selectedCatCoat.catStyle.rawValue) ? model.selectedCatCoat.catStyle.rawValue : "white"
        }
        SeasonPackCenter.shared.configure(host: shared, configuration: .init(
            storeRoot: storeRoot,
            urlForKey: { TripRelay.url("/public/assets/\($0)") },
            allowsLargeDownload: { OfflineVectorNetworkStatus.shared.current.allowsCaching },
            backgroundSessionID: backgroundSessionID
        ))
        SeasonPackCenter.shared.recompute()
        // 센터는 팩을 뒤에서 읽는다. 다 읽기 전에는 켜진 팩이 없어 보여 그림을 지우게 되므로, 읽은 뒤에만 내보낸다(SPL1120A01).
        Task { @MainActor in
            await SeasonPackCenter.shared.reload()
            didLoadPacks = true
            exportWidgetArt()
        }
    }

    @MainActor private static var didLoadPacks = false

    /// 앱 진입·`scenePhase == .active`: 팩 새로고침(30분 쿨다운·ETag·8초·조용한 실패는 패키지가 지킨다).
    @MainActor static func refresh() async {
        await SeasonPackCenter.shared.refresh()
        if didLoadPacks { exportWidgetArt() }
    }

    /// 잠금화면·다이나믹 아일랜드가 쓸 모자·아이콘을 그룹 공간에 둔다(SPL1120A01). 팩이 꺼져 있으면 지운다.
    @MainActor static func exportWidgetArt(root: URL? = TaptionPlanSharedContainer.containerURL()) {
        let center = SeasonPackCenter.shared
        let hat = center.accessoryImageData("hat")
        let icon = center.active.flatMap { pack in pack.manifest.menuIcons?.first.flatMap { pack.assetData($0.icon) } }
        for (kind, data) in [(TaptionSeasonArt.Kind.hat, hat), (.icon, icon)] {
            guard let url = TaptionSeasonArt.url(kind, root: root) else { continue }
            writeArt(data.flatMap(smallPNG), to: url)
        }
    }

    /// 긴 변을 `TaptionSeasonArt.maximumPixels` 이하로 줄인 PNG. 읽지 못하면 nil.
    static func smallPNG(_ data: Data) -> Data? {
        guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else { return nil }
        let pixels = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let ratio = min(1, TaptionSeasonArt.maximumPixels / max(pixels.width, pixels.height))
        let size = CGSize(width: (pixels.width * ratio).rounded(), height: (pixels.height * ratio).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let png = UIGraphicsImageRenderer(size: size, format: format).pngData { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        return png.count <= TaptionSeasonArt.maximumBytes ? png : nil
    }

    /// 바뀐 때만 쓰고, 없으면 지운다. 쓰거나 지웠으면 참.
    @discardableResult
    static func writeArt(_ data: Data?, to url: URL, fileManager: FileManager = .default) -> Bool {
        guard let data else {
            guard fileManager.fileExists(atPath: url.path) else { return false }
            try? fileManager.removeItem(at: url)
            return true
        }
        if (try? Data(contentsOf: url)) == data { return false }
        try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    /// 「모든 데이터 삭제」: 받은 팩·메모·시연 기록을 지운다(센터가 아직 없어도 폴더는 지운다).
    @MainActor static func deleteAll() {
        SeasonPackCenter.shared.deleteAll()
        try? FileManager.default.removeItem(at: storeRoot)
    }

    // MARK: 화면 어댑터

    /// 팩이 모자 칸을 덮어쓰고 있으면 그 그림(`HwarangSceneView`의 `hatImage`). 없으면 nil이라 기존 모자 그대로다.
    @MainActor static func hatImage() -> UIImage? {
        SeasonPackCenter.shared.accessoryImage("hat").map { UIImage(cgImage: $0, scale: 3, orientation: .up) }
    }

    /// 팩이 주는 복장(빨간 코·귀마개·목도리·리본). 리그가 모든 동작에 같게 그린다. 없으면 nil이라 기존 모습 그대로다.
    @MainActor static func look() -> HwarangSeasonLook? {
        guard let c = SeasonPackCenter.shared.costume else { return nil }
        func cloth(_ v: SeasonPackManifest.Slots.Costume.Cloth?) -> HwarangClothStyle? {
            guard let v, let base = hex(v.base), let shade = hex(v.shade), let accent = hex(v.accent), let trim = hex(v.trim) else { return nil }
            let pattern: HwarangClothPattern = switch v.pattern {
            case "bands": .bands
            case "dots": .dots
            case "waves": .waves
            case "check": .check
            case "diamonds": .diamonds
            case "zigzag": .zigzag
            case "scales": .scales
            default: .stripes
            }
            return HwarangClothStyle(base: base, shade: shade, accent: accent, trim: trim, pattern: pattern)
        }
        let look = HwarangSeasonLook(redNose: c.redNose ?? false, cape: c.cape ?? false, scarf: cloth(c.scarf), ribbon: cloth(c.ribbon),
                                     hat: SeasonPackCenter.shared.accessoryImage("hat") != nil)
        return look.isEmpty ? nil : look
    }

    private static func hex(_ text: String) -> UInt32? {
        text.count == 6 ? UInt32(text, radix: 16) : nil
    }

    /// 하루 공유 카드에 쓸 이벤트 그림(이벤트가 없으면 nil이라 카드는 지금과 똑같다). 그림은 미리 읽어 둔 것이라 렌더 중 디스크를 읽지 않는다.
    @MainActor static func cardArt() -> SeasonCardArt? {
        let center = SeasonPackCenter.shared
        guard center.active != nil else { return nil }
        return SeasonCardArt(
            house: center.shareCardHouseImage().map { UIImage(cgImage: $0) },
            hat: hatImage(),
            look: look(),
            layers: center.characterLayers(includeOutfit: center.shareCardUsesOutfit, includeHat: false)
        )
    }

    /// 캐릭터 위에 얹는 팩 레이어(의상·목도리·뿔). 모자는 화랑이 리그가 직접 씌운다.
    @MainActor static func characterLayers() -> [(image: CGImage, layer: SeasonPackManifest.Layer)] {
        SeasonPackCenter.shared.characterLayers(includeHat: false)
    }

    /// 대사 풀 앞에 둘 이벤트 대사(기간 밖이면 빈 목록).
    static func eventPhrases(languageCode: String) -> [String] {
        SeasonPackPhrases.current(language: languageCode)
    }
}

/// 하루 공유 카드가 쓰는 시즌 그림 한 묶음(`MapHomeDailyCardView`의 인자 하나).
struct SeasonCardArt {
    let house: UIImage?
    let hat: UIImage?
    let look: HwarangSeasonLook?
    let layers: [(image: CGImage, layer: SeasonPackManifest.Layer)]
}
