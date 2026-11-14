import MapKit
import SwiftUI
import TaptionPlanStore

/// 여행 전 계획 단계의 장소 사진(TVV1113A01 C6): 위키백과의 대표 사진을 그때그때 받아 작게 보인다.
/// 우리 서버는 없다. 장소 이름과 좌표가 위키미디어로 나가므로, 연락처가 설정돼 있고 사용자가 켜 둔 때만 받는다.
struct TravelPlacePhoto: Equatable {
    /// 어디서 온 그림인지(PHX1114A01). 웹 검색 사진과 지도 그림은 기기에 오래 두지 않는다.
    enum Source: String { case wiki, commons, web, street, map }

    var image: UIImage
    /// 저작권 표시(작가 · 라이선스) 또는 출처 사이트. 지도 그림은 비어 있다.
    var credit: String
    var source: Source = .wiki
}

/// 위키백과 요청과 응답 읽기. 네트워크 없이 시험할 수 있게 계산만 둔다.
enum TravelWikiPhoto {
    struct Candidate: Equatable {
        var title: String
        var file: String
        var thumbnail: URL
    }

    /// 위키미디어 규칙: 앱 이름과 연락처를 밝힌다. 연락처가 없으면 nil(요청하지 않는다).
    static func userAgent(contact: String?, version: String) -> String? {
        guard let contact = contact?.trimmingCharacters(in: .whitespacesAndNewlines), !contact.isEmpty, !contact.hasPrefix("$(") else { return nil }
        return "BOKKIPlan/\(version) (\(contact))"
    }

    /// 이름의 글자로 어느 언어 위키백과에서 찾을지 고른다: 한글 → ko, 가나·한자 → ja, 그 밖 → en.
    static func language(for name: String) -> String {
        var hangul = 0, japanese = 0
        for scalar in name.unicodeScalars {
            switch scalar.value {
            case 0xAC00...0xD7A3, 0x1100...0x11FF, 0x3130...0x318F: hangul += 1
            case 0x3040...0x30FF, 0x4E00...0x9FFF: japanese += 1
            default: break
            }
        }
        return hangul > 0 ? "ko" : japanese > 0 ? "ja" : "en"
    }

    /// 견줄 때 쓰는 이름: 소문자, 띄어쓰기·문장부호 없음.
    static func normalized(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    private static func api(_ language: String, _ items: [URLQueryItem]) -> URL? {
        var parts = URLComponents(string: "https://\(language).wikipedia.org/w/api.php")
        parts?.queryItems = [.init(name: "action", value: "query"), .init(name: "format", value: "json"), .init(name: "formatversion", value: "2")] + items
        return parts?.url
    }

    /// 이름으로 찾기: 대표 사진(가로 320)과 좌표를 함께 받는다.
    static func searchURL(name: String, language: String) -> URL? {
        api(language, [
            .init(name: "generator", value: "search"), .init(name: "gsrsearch", value: name), .init(name: "gsrlimit", value: "5"),
            .init(name: "prop", value: "pageimages|coordinates"), .init(name: "piprop", value: "thumbnail|name"),
            .init(name: "pithumbsize", value: "320"), .init(name: "colimit", value: "5"),
        ])
    }

    /// 사진의 작가·라이선스.
    static func creditURL(file: String, language: String) -> URL? {
        api(language, [
            .init(name: "titles", value: "File:" + file), .init(name: "prop", value: "imageinfo"),
            .init(name: "iiprop", value: "extmetadata"), .init(name: "iiextmetadatafilter", value: "Artist|LicenseShortName"),
        ])
    }

    static func meters(_ latitude: Double, _ longitude: Double, _ otherLatitude: Double, _ otherLongitude: Double) -> Double {
        let radians = Double.pi / 180, dLat = (otherLatitude - latitude) * radians, dLon = (otherLongitude - longitude) * radians
        let a = sin(dLat / 2) * sin(dLat / 2) + cos(latitude * radians) * cos(otherLatitude * radians) * sin(dLon / 2) * sin(dLon / 2)
        return 6_371_000 * 2 * atan2(sqrt(a), sqrt(1 - a))
    }

    /// 찾은 항목 가운데 쓸 것: 사진이 있고(그림 파일 제외), 그 항목의 좌표가 핀에서 3km 안.
    /// 이름이 같거나 서로 품는 항목을 먼저, 없으면 찾은 순서의 첫 항목. 좌표가 없는 항목은 엉뚱한 곳일 수 있어 쓰지 않는다.
    static func pick(_ data: Data, name: String, latitude: Double, longitude: Double, withinMeters: Double = 3_000) -> Candidate? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pages = (root["query"] as? [String: Any])?["pages"] as? [[String: Any]] else { return nil }
        let wanted = normalized(name)
        var found: [(index: Int, isMatch: Bool, candidate: Candidate)] = []
        for page in pages {
            guard let title = page["title"] as? String, let file = page["pageimage"] as? String,
                  let source = (page["thumbnail"] as? [String: Any])?["source"] as? String, let thumbnail = URL(string: source),
                  !file.lowercased().hasSuffix(".svg"),
                  let spots = page["coordinates"] as? [[String: Any]],
                  spots.contains(where: { spot in
                      guard let lat = spot["lat"] as? Double, let lon = spot["lon"] as? Double else { return false }
                      return meters(latitude, longitude, lat, lon) <= withinMeters
                  }) else { continue }
            let key = normalized(title)
            let isMatch = !key.isEmpty && !wanted.isEmpty && (key == wanted || key.contains(wanted) || wanted.contains(key))
            found.append((page["index"] as? Int ?? Int.max, isMatch, Candidate(title: title, file: file, thumbnail: thumbnail)))
        }
        return found.sorted { ($0.isMatch ? 0 : 1, $0.index) < ($1.isMatch ? 0 : 1, $1.index) }.first?.candidate
    }

    /// 「작가 · 라이선스」. 라이선스가 없으면 nil(그 사진을 쓰지 않는다). 작가 글의 HTML 꼬리표는 걷어 낸다.
    static func credit(_ data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pages = (root["query"] as? [String: Any])?["pages"] as? [[String: Any]],
              let meta = ((pages.first?["imageinfo"] as? [[String: Any]])?.first?["extmetadata"]) as? [String: Any] else { return nil }
        func value(_ key: String) -> String {
            let raw = (meta[key] as? [String: Any])?["value"] as? String ?? ""
            let plain = raw.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&nbsp;", with: " ")
            return String(plain.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces).prefix(60))
        }
        let license = value("LicenseShortName")
        guard !license.isEmpty else { return nil }
        let artist = value("Artist")
        return (artist.isEmpty ? "" : artist + " · ") + license + " · Wikimedia Commons"
    }

    // MARK: 위키미디어 공용의 주변 사진 (PHX1114A01)

    /// 좌표 근처에서 찍힌 공개 사진을 가까운 순으로 찾는다. 장소 이름이 위키백과에 없어도 나온다.
    static func commonsURL(latitude: Double, longitude: Double, radiusMeters: Int = 300) -> URL? {
        var parts = URLComponents(string: "https://commons.wikimedia.org/w/api.php")
        parts?.queryItems = [
            .init(name: "action", value: "query"), .init(name: "format", value: "json"), .init(name: "formatversion", value: "2"),
            .init(name: "generator", value: "geosearch"), .init(name: "ggscoord", value: String(format: "%.5f|%.5f", latitude, longitude)),
            .init(name: "ggsradius", value: String(radiusMeters)), .init(name: "ggsnamespace", value: "6"), .init(name: "ggslimit", value: "12"),
            .init(name: "prop", value: "imageinfo"), .init(name: "iiprop", value: "url|extmetadata|mime"),
            .init(name: "iiurlwidth", value: "640"), .init(name: "iiextmetadatafilter", value: "Artist|LicenseShortName"),
        ]
        return parts?.url
    }

    /// 찾은 것 가운데 쓸 사진: 사진 파일(JPEG)이고 라이선스가 적혀 있는 첫 장. 지도·도면·로고(SVG·PNG)는 쓰지 않는다.
    static func pickCommons(_ data: Data) -> (thumbnail: URL, credit: String)? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pages = (root["query"] as? [String: Any])?["pages"] as? [[String: Any]] else { return nil }
        for page in pages.sorted(by: { ($0["index"] as? Int ?? .max) < ($1["index"] as? Int ?? .max) }) {
            guard let info = (page["imageinfo"] as? [[String: Any]])?.first, info["mime"] as? String == "image/jpeg",
                  let link = info["thumburl"] as? String, let thumbnail = URL(string: link),
                  let meta = try? JSONSerialization.data(withJSONObject: ["query": ["pages": [["imageinfo": [info]]]]]),
                  let credit = credit(meta) else { continue }
            return (thumbnail, credit)
        }
        return nil
    }

    // MARK: 웹 이미지 검색 (PHX1114A01). 우리 서버가 카카오 검색을 대신 부른다.

    struct WebCandidate: Equatable {
        var image: URL
        var site: String
    }

    /// 쓸 만한 사진: 너무 작지 않고(긴 쪽 300 이상), 지나치게 길쭉하지 않은 것. 큰 사진 주소가 없으면 작은 그림 주소.
    static func pickWeb(_ data: Data) -> [WebCandidate] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let documents = root["documents"] as? [[String: Any]] else { return [] }
        return documents.compactMap { item in
            let width = item["width"] as? Double ?? 0, height = item["height"] as? Double ?? 0
            guard max(width, height) >= 300, min(width, height) > 0, max(width, height) / min(width, height) <= 2.5,
                  let link = (item["image"] as? String) ?? (item["thumbnail"] as? String), let url = URL(string: link), url.scheme == "https" else { return nil }
            return WebCandidate(image: url, site: (item["site"] as? String ?? "").trimmingCharacters(in: .whitespaces))
        }
    }

    /// 우리 서버의 사진 중계(`/photo/search`)가 돌려준 것: 사진 주소와 출처 표시(PHS1114A01).
    static func pickRelay(_ data: Data) -> [WebCandidate] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let documents = root["documents"] as? [[String: Any]] else { return [] }
        return documents.compactMap { item in
            guard let link = item["image"] as? String, let url = URL(string: link), url.scheme == "https" else { return nil }
            return WebCandidate(image: url, site: (item["site"] as? String ?? "").trimmingCharacters(in: .whitespaces))
        }
    }

    /// 기기 캐시의 파일 이름표: 이름과 좌표 네 자리. 일정이 다른 곳으로 옮겨지면 다시 찾는다.
    static func cacheKey(name: String, latitude: Double, longitude: Double) -> String {
        let text = normalized(name) + String(format: "|%.4f|%.4f", latitude, longitude)
        // 파일 이름으로 쓸 수 있게 FNV-1a 64비트로 줄인다(충돌해도 사진 한 장이 바뀔 뿐이다).
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        return String(hash, radix: 16)
    }

    /// 캐시가 상한을 넘을 때 지울 파일들: 오래 안 쓴 것부터.
    static func evictions(_ files: [(name: String, bytes: Int, usedAt: Date)], limitBytes: Int) -> [String] {
        var total = files.reduce(0) { $0 + $1.bytes }, removed: [String] = []
        for file in files.sorted(by: { $0.usedAt < $1.usedAt }) where total > limitBytes {
            total -= file.bytes
            removed.append(file.name)
        }
        return removed
    }
}

/// 일정 번호 → 장소 사진. 보이는 곳부터 하나씩 차례로 받는다(위키미디어가 잦은 요청을 막으므로 사이를 둔다).
/// 받은 사진은 `Caches/TravelPlacePhotos`에 둔다(파생 캐시: 30MB까지, 오래 안 쓴 것부터 지움, 백업에 들지 않음).
@MainActor @Observable
final class TravelPlacePhotoStore {
    struct Place: Equatable {
        var itemID: String
        var name: String
        var latitude: Double
        var longitude: Double
    }

    static let limitBytes = 30 * 1_024 * 1_024
    /// 못 찾은 곳을 다시 묻지 않는 동안.
    static let missSeconds: TimeInterval = 7 * 86_400
    /// 웹에서 찾은 사진은 기기에 하루만 둔다(남의 사진이라 오래 저장하지 않는다).
    static let webSeconds: TimeInterval = 86_400

    private(set) var photos: [String: TravelPlacePhoto] = [:]
    @ObservationIgnored private var asked: Set<String> = []
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let folder: URL?
    @ObservationIgnored private let agent: String?

    init(session: URLSession = .shared) {
        self.session = session
        folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("TravelPlacePhotos", isDirectory: true)
        agent = TravelWikiPhoto.userAgent(
            contact: Bundle.main.object(forInfoDictionaryKey: "WIKIMEDIA_CONTACT") as? String,
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1"
        )
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.dropMemory() }
        }
    }

    /// 연락처가 설정돼 있어 받을 수 있는지.
    var isAvailable: Bool { agent != nil }

    /// 메모리 압력: 화면에 올린 그림을 비운다(기기 캐시는 남아 다시 읽힌다).
    private func dropMemory() {
        photos.removeAll()
        asked.removeAll()
    }

    func load(_ places: [Place]) async {
        guard let folder else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for place in places where photos[place.itemID] == nil {
            if Task.isCancelled { return }
            let key = TravelWikiPhoto.cacheKey(name: place.name, latitude: place.latitude, longitude: place.longitude)
            guard asked.insert(place.itemID + key).inserted else { continue }
            if let cached = readCache(key, in: folder) {
                photos[place.itemID] = cached
                continue
            }
            if isRecentMiss(key, in: folder) {
                // 사진을 못 찾은 곳은 작은 지도 그림으로 채운다(기기에 저장하지 않는다).
                if let picture = await fallbackPicture(place) { photos[place.itemID] = picture }
                continue
            }
            let fetched = await fetch(place)
            if let fetched, let data = fetched.image.jpegData(compressionQuality: 0.85) {
                try? data.write(to: folder.appendingPathComponent(key + ".jpg"))
                try? Data((fetched.source.rawValue + "\n" + fetched.credit).utf8).write(to: folder.appendingPathComponent(key + ".txt"))
                photos[place.itemID] = fetched
                trim(folder)
            } else {
                try? Data().write(to: folder.appendingPathComponent(key + ".none"))
                if let picture = await fallbackPicture(place) { photos[place.itemID] = picture }
            }
            // 잇달아 물으면 막힌다(429). 한 곳에 요청이 셋까지라 사이를 둔다.
            try? await Task.sleep(for: .milliseconds(1_200))
        }
    }

    private func readCache(_ key: String, in folder: URL) -> TravelPlacePhoto? {
        let file = folder.appendingPathComponent(key + ".jpg")
        guard let data = try? Data(contentsOf: file), let image = UIImage(data: data),
              let note = try? String(contentsOf: folder.appendingPathComponent(key + ".txt"), encoding: .utf8), !note.isEmpty else { return nil }
        // 첫 줄이 출처 종류다. 예전 파일은 한 줄(저작권 표시)뿐이고 위키백과 것이다.
        let lines = note.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let source = lines.count == 2 ? TravelPlacePhoto.Source(rawValue: lines[0]) ?? .wiki : .wiki
        let credit = lines.count == 2 ? lines[1] : note
        if source == .web {
            let saved = (try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(key + ".txt").path))?[.modificationDate] as? Date ?? .distantPast
            guard Date().timeIntervalSince(saved) < Self.webSeconds else {
                for suffix in [".jpg", ".txt"] { try? FileManager.default.removeItem(at: folder.appendingPathComponent(key + suffix)) }
                return nil
            }
        } else {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        }
        return TravelPlacePhoto(image: image, credit: credit, source: source)
    }

    private func isRecentMiss(_ key: String, in folder: URL) -> Bool {
        let path = folder.appendingPathComponent(key + ".none").path
        guard let date = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date else { return false }
        return Date().timeIntervalSince(date) < Self.missSeconds
    }

    private func get(_ url: URL?) async -> Data? {
        guard let url, let agent else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue(agent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    /// 차례로 찾는다(PHX1114A01·PHS1114A01): 위키백과 대표 사진 → 위키미디어 공용의 주변 사진 → (국내) 관광공사 → 웹 이미지 검색
    /// → Mapillary 거리 사진 → Unsplash·Pexels. 키가 없는 출처는 서버가 꺼 두어 그냥 지나간다. 그래도 없으면 `load`가 주변 보기·지도 그림으로 채운다.
    private func fetch(_ place: Place) async -> TravelPlacePhoto? {
        if let photo = await wikiPhoto(place) { return photo }
        if let photo = await commonsPhoto(place) { return photo }
        let spot = [URLQueryItem(name: "lat", value: String(format: "%.5f", place.latitude)), URLQueryItem(name: "lng", value: String(format: "%.5f", place.longitude))]
        let name = URLQueryItem(name: "query", value: String(place.name.prefix(100)))
        if MapHomeKakaoSearch.isInKorea(CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude)),
           let photo = await relayPhoto([.init(name: "source", value: "tour"), name] + spot) { return photo }
        if let photo = await webPhoto(place) { return photo }
        if let photo = await relayPhoto([.init(name: "source", value: "mapillary")] + spot) { return photo }
        for source in ["unsplash", "pexels"] {
            if let photo = await relayPhoto([.init(name: "source", value: source), name]) { return photo }
        }
        return nil
    }

    /// 우리 서버의 사진 중계에서 받은 첫 장. 사진은 그 출처에서 바로 받는다.
    private func relayPhoto(_ items: [URLQueryItem]) async -> TravelPlacePhoto? {
        guard let host = TripRelay.host, let token = await AssistantRegistration.searchToken(), var parts = URLComponents(string: "https://\(host)/photo/search") else { return nil }
        parts.queryItems = items
        guard let url = parts.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await session.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        for candidate in TravelWikiPhoto.pickRelay(data).prefix(2) {
            guard let (bytes, reply) = try? await session.data(from: candidate.image), (reply as? HTTPURLResponse)?.statusCode == 200,
                  bytes.count <= 4_000_000, let image = UIImage(data: bytes), let small = image.preparingThumbnail(of: Self.fitted(image.size, longSide: 640)) else { continue }
            return TravelPlacePhoto(image: small, credit: candidate.site.isEmpty ? "web" : candidate.site, source: .web)
        }
        return nil
    }

    /// Apple 「주변 보기」의 거리 풍경 한 컷. 없는 지역이 많다. 그때그때 그리고 기기에 저장하지 않는다.
    private func streetPicture(_ place: Place) async -> TravelPlacePhoto? {
        guard abs(place.latitude) <= 90, abs(place.longitude) <= 180, !(place.latitude == 0 && place.longitude == 0),
              let scene = try? await MKLookAroundSceneRequest(coordinate: CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude)).scene else { return nil }
        let options = MKLookAroundSnapshotter.Options()
        options.size = CGSize(width: 320, height: 240)
        guard let snapshot = try? await MKLookAroundSnapshotter(scene: scene, options: options).snapshot else { return nil }
        return TravelPlacePhoto(image: snapshot.image, credit: "", source: .street)
    }

    /// 사진을 못 찾은 곳을 채우는 그림: 주변 보기, 없으면 작은 지도.
    private func fallbackPicture(_ place: Place) async -> TravelPlacePhoto? {
        if let street = await streetPicture(place) { return street }
        return await mapPicture(place)
    }

    private func wikiPhoto(_ place: Place) async -> TravelPlacePhoto? {
        let language = TravelWikiPhoto.language(for: place.name)
        guard let found = await get(TravelWikiPhoto.searchURL(name: place.name, language: language)),
              let pick = TravelWikiPhoto.pick(found, name: place.name, latitude: place.latitude, longitude: place.longitude),
              let meta = await get(TravelWikiPhoto.creditURL(file: pick.file, language: language)), let credit = TravelWikiPhoto.credit(meta),
              let bytes = await get(pick.thumbnail), let image = UIImage(data: bytes) else { return nil }
        return TravelPlacePhoto(image: image, credit: credit, source: .wiki)
    }

    private func commonsPhoto(_ place: Place) async -> TravelPlacePhoto? {
        guard let found = await get(TravelWikiPhoto.commonsURL(latitude: place.latitude, longitude: place.longitude)),
              let pick = TravelWikiPhoto.pickCommons(found), let bytes = await get(pick.thumbnail), let image = UIImage(data: bytes) else { return nil }
        return TravelPlacePhoto(image: image, credit: pick.credit, source: .commons)
    }

    /// 장소 이름으로 웹에서 찾는다. 우리 서버가 검색만 대신 하고, 사진은 그 사이트에서 바로 받는다. 출처 사이트 이름을 함께 보인다.
    private func webPhoto(_ place: Place) async -> TravelPlacePhoto? {
        guard let host = TripRelay.host, let token = await AssistantRegistration.searchToken(), var parts = URLComponents(string: "https://\(host)/kakao/image") else { return nil }
        parts.queryItems = [.init(name: "query", value: String(place.name.prefix(100)))]
        guard let url = parts.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await session.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        for candidate in TravelWikiPhoto.pickWeb(data).prefix(3) {
            var picture = URLRequest(url: candidate.image, timeoutInterval: 10)
            picture.setValue("image/*", forHTTPHeaderField: "Accept")
            guard let (bytes, reply) = try? await session.data(for: picture), (reply as? HTTPURLResponse)?.statusCode == 200,
                  bytes.count <= 4_000_000, let image = UIImage(data: bytes), let small = image.preparingThumbnail(of: Self.fitted(image.size, longSide: 640)) else { continue }
            return TravelPlacePhoto(image: small, credit: candidate.site.isEmpty ? "web" : candidate.site, source: .web)
        }
        return nil
    }

    nonisolated static func fitted(_ size: CGSize, longSide: CGFloat) -> CGSize {
        let scale = min(1, longSide / max(size.width, size.height, 1))
        return CGSize(width: max(1, size.width * scale), height: max(1, size.height * scale))
    }

    /// 사진이 없는 곳: 그 자리의 작은 지도 한 컷. 그때그때 그리고 기기에 저장하지 않는다(Apple 지도 타일은 저장하지 않는다).
    private func mapPicture(_ place: Place) async -> TravelPlacePhoto? {
        guard abs(place.latitude) <= 90, abs(place.longitude) <= 180, !(place.latitude == 0 && place.longitude == 0) else { return nil }
        let options = MKMapSnapshotter.Options()
        options.region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude), latitudinalMeters: 500, longitudinalMeters: 500)
        options.size = CGSize(width: 240, height: 240)
        options.pointOfInterestFilter = .includingAll
        guard let snapshot = try? await MKMapSnapshotter(options: options).start() else { return nil }
        return TravelPlacePhoto(image: snapshot.image, credit: "", source: .map)
    }

    private func trim(_ folder: URL) {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
        let sized = files.compactMap { file -> (name: String, bytes: Int, usedAt: Date)? in
            guard let values = try? file.resourceValues(forKeys: Set(keys)) else { return nil }
            return (file.lastPathComponent, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }
        for name in TravelWikiPhoto.evictions(sized, limitBytes: Self.limitBytes) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }
}
