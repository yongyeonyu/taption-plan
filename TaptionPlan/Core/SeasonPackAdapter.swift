import Foundation
import SeasonPackKit
import Synchronization
import TaptionAssistantKit
import UIKit

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
            allowsLargeDownload: { OfflineVectorNetworkStatus.shared.current.allowsCaching }
        ))
        SeasonPackCenter.shared.recompute()
    }

    /// 앱 진입·`scenePhase == .active`: 팩 새로고침(30분 쿨다운·ETag·8초·조용한 실패는 패키지가 지킨다).
    @MainActor static func refresh() async { await SeasonPackCenter.shared.refresh() }

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

    /// 하루 공유 카드에 쓸 이벤트 그림(이벤트가 없으면 nil이라 카드는 지금과 똑같다). 그림은 미리 읽어 둔 것이라 렌더 중 디스크를 읽지 않는다.
    @MainActor static func cardArt() -> SeasonCardArt? {
        let center = SeasonPackCenter.shared
        guard center.active != nil else { return nil }
        return SeasonCardArt(
            house: center.shareCardHouseImage().map { UIImage(cgImage: $0) },
            hat: hatImage(),
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
    let layers: [(image: CGImage, layer: SeasonPackManifest.Layer)]
}
