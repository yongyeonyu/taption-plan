import CoreGraphics
import Foundation
import Observation
import Synchronization

/// 시즌 팩의 상태 허브(앱당 하나). 팩을 읽고(시드·설치본), 시계로 지금 켜질 팩을 고르고, 다음 경계까지 타이머 하나를 건다.
/// 팩이 없거나 손상·미수신이거나 기간 밖이면 `active`가 nil이라 앱은 지금과 똑같이 보인다.
@MainActor
@Observable
public final class SeasonPackCenter {
    public static let shared = SeasonPackCenter()

    public struct Configuration: Sendable {
        public var storeRoot: URL
        public var urlForKey: @Sendable (String) -> URL?
        public var allowsLargeDownload: @Sendable () -> Bool
        public var defaultsSuite: String?

        public init(storeRoot: URL, urlForKey: @escaping @Sendable (String) -> URL?, allowsLargeDownload: @escaping @Sendable () -> Bool = { true }, defaultsSuite: String? = nil) {
            self.storeRoot = storeRoot; self.urlForKey = urlForKey; self.allowsLargeDownload = allowsLargeDownload; self.defaultsSuite = defaultsSuite
        }
    }

    public private(set) var packs: [SeasonPack] = []
    public private(set) var active: SeasonPack?
    /// 마지막 판정에 쓴 이벤트 시각(의심이면 nil).
    public private(set) var eventDate: Date?
    public var motion = SeasonPackMotionPolicy() {
        didSet { if motion != oldValue { stage.motionChanged() } }
    }

    @ObservationIgnored public let stage = SeasonPackStage()
    @ObservationIgnored public private(set) var host: (any SeasonPackHost)?
    @ObservationIgnored public private(set) var store: SeasonPackStore?
    @ObservationIgnored public private(set) var memoStore: SeasonPackMemoStore?
    @ObservationIgnored public private(set) var clock: SeasonPackClock?
    @ObservationIgnored private var fetcher: SeasonPackFetcher?
    @ObservationIgnored private(set) var defaults = SeasonPackDefaults()
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var previewID: String?
    @ObservationIgnored private var previewBase: (device: Date, event: Date)?
    @ObservationIgnored private var lastAnnounced: String?
    @ObservationIgnored private let versionBook = SeasonPackVersionBook()

    public init() {}

    /// 판정에 쓰는 달력(기기 시간대). 시험이 시간대를 고정할 때 바꾼다.
    @ObservationIgnored public var calendar: Calendar = .current

    public var windows: SeasonPackWindows {
        let host = host
        let preview = previewID != nil
        return SeasonPackWindows(calendar: calendar, sun: { day in
            let events: (sunrise: Date?, sunset: Date?) = host?.sunEvents(on: day) ?? (nil, nil)
            if events.sunrise == nil, events.sunset == nil, preview {
                let cal = Calendar.current
                return SeasonPackSunTimes(sunrise: cal.date(bySettingHour: 6, minute: 0, second: 0, of: day), sunset: cal.date(bySettingHour: 18, minute: 0, second: 0, of: day))
            }
            return SeasonPackSunTimes(sunrise: events.sunrise, sunset: events.sunset)
        })
    }

    /// 앱이 한 번 부른다. 이미 설정돼 있으면 아무것도 하지 않는다.
    public func configure(host: any SeasonPackHost, configuration: Configuration) {
        guard self.host == nil else { return }
        self.host = host
        defaults = SeasonPackDefaults(suiteName: configuration.defaultsSuite)
        let store = SeasonPackStore(root: configuration.storeRoot)
        self.store = store
        memoStore = SeasonPackMemoStore(directory: configuration.storeRoot.appendingPathComponent(SeasonPackStore.memosFolder, isDirectory: true))
        let clock = SeasonPackClock(
            storage: SeasonPackDefaultsClockStorage(suiteName: configuration.defaultsSuite),
            deviceNow: { [host] in host.now() }
        )
        self.clock = clock
        fetcher = SeasonPackFetcher(
            store: store,
            transport: SeasonPackURLSessionTransport(urlForKey: configuration.urlForKey),
            defaults: defaults,
            appBuild: { [host] in host.buildNumber },
            now: { [host] in host.now() },
            windows: { SeasonPackWindows() },
            allowsLargeDownload: configuration.allowsLargeDownload,
            knownVersion: { [book = versionBook] id in book.version(of: id) },
            onServerDate: { clock.recordServerDate($0) }
        )
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-seasonPackPreview"), arguments.indices.contains(index + 1) { previewID = arguments[index + 1] }
        if let date = SeasonPackClock.debugDateFromLaunchArguments() { clock.setDebugDate({ date }) }
#endif
        stage.attach(center: self)
        Task { await reload() }
    }

    /// 시드와 디스크의 설치본을 읽어 합친다(디스크 읽기는 메인을 막지 않게 다른 큐에서).
    public func reload() async {
        guard let store, let host else { return }
        let build = host.buildNumber
        let loaded: [SeasonPack] = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let merged = SeasonPackSeed.merge(installed: store.installedPacks(appBuild: build), seeds: SeasonPackSeed.bundledPacks(appBuild: build))
                for pack in merged { SeasonPackImageCache.shared.preload(pack: pack) }
                continuation.resume(returning: merged)
            }
        }
        packs = loaded
        versionBook.set(Dictionary(loaded.map { ($0.id, $0.version) }, uniquingKeysWith: max))
        recompute()
    }

    /// 앱 진입·`scenePhase == .active`에서 부른다(30분 쿨다운은 받기 쪽이 지킨다).
    public func refresh() async {
        guard let fetcher else { return }
        let result = await fetcher.refresh()
        if !result.installed.isEmpty { await reload() } else { recompute() }
    }

    /// 지금 켜질 팩을 다시 판정한다.
    public func recompute() {
        guard let clock else { return }
        var date = clock.eventDate
        var chosen: SeasonPack?
        if let date {
            chosen = windows.activePack(in: packs.map(\.manifest), at: date).flatMap { manifest in packs.first { $0.id == manifest.id && $0.version == manifest.version } }
        }
#if DEBUG
        if let previewID, let pack = packs.first(where: { $0.id == previewID }), let host {
            if previewBase == nil { previewBase = (host.now(), previewDate(for: pack, fallback: date ?? host.now())) }
            if let base = previewBase { date = base.event.addingTimeInterval(host.now().timeIntervalSince(base.device)) }
            chosen = pack
        }
#endif
        eventDate = date
        let changed = chosen?.id != active?.id || chosen?.version != active?.version
        active = chosen
        if changed { stage.activePackChanged() }
        if let chosen { store?.touch(id: chosen.id, version: chosen.version, now: host?.now() ?? Date()) }
        announceIfNeeded()
        armTimer()
    }

    /// 팩이 처음 활성화됐을 때 그 팩의 공지를 기존 공지 시트로 한 번 보여 준다(공지를 아직 못 받았으면 다음 판정 때 다시 시도).
    private func announceIfNeeded() {
        guard let pack = active, let id = pack.manifest.event.announcementId, let host else { return }
        let key = "seasonPack.announced.\(id)"
        guard !defaults.bool(key), lastAnnounced != id else { return }
        if host.presentAnnouncement(id: id) {
            defaults.set(true, key)
            lastAnnounced = id
        }
    }

    private func armTimer() {
        timer?.cancel()
        guard let date = eventDate else {
            timer = Task { [weak self] in
                try? await Task.sleep(for: .seconds(300))
                if !Task.isCancelled { self?.recompute() }
            }
            return
        }
        guard let next = SeasonPackTriggers.nextTransition(packs: packs.map(\.manifest), after: date, windows: windows) else { return }
        let wait = max(1, next.timeIntervalSince(date))
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            if !Task.isCancelled { self?.recompute() }
        }
    }

#if DEBUG
    private func previewDate(for pack: SeasonPack, fallback: Date) -> Date {
        let year = calendar.component(.year, from: fallback)
        for window in pack.manifest.event.windows {
            for startYear in [year, year + 1, year - 1] {
                if let span = windows.interval(of: window, startYear: startYear) {
                    let middle = span.start.addingTimeInterval(span.duration / 2)
                    return calendar.date(bySettingHour: 21, minute: 0, second: 0, of: middle) ?? middle
                }
            }
        }
        return fallback
    }
#endif

    // MARK: 화면이 읽는 값

    public var activeYear: Int? { eventDate.map { calendar.component(.year, from: $0) } }

    public func houseState() -> SeasonPackHouseState? {
        guard let active, let eventDate else { return nil }
        return SeasonPackRenderer.houseState(pack: active, now: eventDate, windows: windows, motion: motion, fastUntil: stage.fastBlinkUntil)
    }

    /// 기본 대사 풀 앞에 둘 이벤트 대사(기간 밖이면 빈 목록).
    public func bubblePhrases(language: String) -> [String] {
        (active?.manifest.slots?.bubbles?.pool ?? []).map { $0.resolve(language: language) }.filter { !$0.isEmpty }
    }

    public func placedIcons(origin: CGPoint = .zero, bounds: CGRect? = nil) -> [SeasonPackPlacedIcon] {
        guard let active, let eventDate, let host else { return [] }
        return SeasonPackIconRegistry.visibleIcons(packs: [active], now: eventDate, language: host.languageCode, calendar: calendar, origin: origin, bounds: bounds)
    }

    /// 하루 공유 카드가 쓸 그림. 이벤트가 없으면 nil이라 카드는 지금과 완전히 같다. 그림은 이미 읽어 둔 것이라 디스크를 기다리지 않는다.
    public func shareCardHouseImage() -> CGImage? {
        guard let active, let id = active.manifest.slots?.shareCard?.house else { return nil }
        return SeasonPackImageCache.shared.image(pack: active, asset: id)
    }

    /// 카드·지도에서 캐릭터 위에 얹을 팩 레이어(의상 → 악세사리, z 순).
    public func characterLayers(characterID: String? = nil, includeOutfit: Bool = true) -> [(image: CGImage, layer: SeasonPackManifest.Layer)] {
        guard let active, let slots = active.manifest.slots else { return [] }
        let character = characterID ?? host?.characterID ?? "white"
        var layers = includeOutfit && (slots.shareCard?.outfit ?? true) ? (slots.outfit?[character] ?? []) : []
        if let accessory = slots.accessory { layers += [accessory.hat, accessory.scarf, accessory.ribbon].compactMap { $0 } }
        return layers.sorted { $0.z < $1.z }.compactMap { layer in
            SeasonPackImageCache.shared.image(pack: active, asset: layer.asset).map { ($0, layer) }
        }
    }

    public var shareCardUsesOutfit: Bool { active?.manifest.slots?.shareCard?.outfit ?? false }

    /// 모자 칸의 팩 그림 바이트(앱의 `HwarangSceneView`가 `hatImage`로 얹는다).
    public func accessoryImageData(_ slot: String) -> Data? {
        guard let active, let accessory = active.manifest.slots?.accessory else { return nil }
        let layer: SeasonPackManifest.Layer? = switch slot {
        case "hat": accessory.hat
        case "scarf": accessory.scarf
        case "ribbon": accessory.ribbon
        default: nil
        }
        return layer.flatMap { active.assetData($0.asset) }
    }

    /// 「모든 데이터 삭제」: 팩·메모·시계·시연 기록을 지운다.
    public func deleteAll() {
        timer?.cancel()
        stage.stopAll()
        store?.removeAll()
        let storeRoot = store?.root
        defaults.removeAll(withPrefix: "seasonPack.")
        SeasonPackImageCache.shared.removeAll()
        packs = []
        active = nil
        if let storeRoot { try? FileManager.default.removeItem(at: storeRoot) }
    }

    /// 지도 어디든 눌렀을 때(그 회차의 비행을 멈춘다).
    public func noteUserTouch() { stage.stopRound() }
}

/// 받기 쪽(메인 밖)이 지금 알고 있는 팩 버전을 묻는 자리.
final class SeasonPackVersionBook: Sendable {
    private let versions = Mutex<[String: Int]>([:])
    func version(of id: String) -> Int { versions.withLock { $0[id] ?? 0 } }
    func set(_ new: [String: Int]) { versions.withLock { $0 = new } }
}
