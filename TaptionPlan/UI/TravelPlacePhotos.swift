import SwiftUI
import TaptionPlanStore

/// 여행 전 계획 단계의 장소 사진(TVV1113A01 C6): 위키백과의 대표 사진을 그때그때 받아 작게 보인다.
/// 우리 서버는 없다. 장소 이름과 좌표가 위키미디어로 나가므로, 연락처가 설정돼 있고 사용자가 켜 둔 때만 받는다.
struct TravelPlacePhoto: Equatable {
    var image: UIImage
    /// 저작권 표시(작가 · 라이선스). 이것이 없는 사진은 쓰지 않는다.
    var credit: String
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
        guard agent != nil, let folder else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for place in places where photos[place.itemID] == nil {
            if Task.isCancelled { return }
            let key = TravelWikiPhoto.cacheKey(name: place.name, latitude: place.latitude, longitude: place.longitude)
            guard asked.insert(place.itemID + key).inserted else { continue }
            if let cached = readCache(key, in: folder) {
                photos[place.itemID] = cached
                continue
            }
            if isRecentMiss(key, in: folder) { continue }
            let fetched = await fetch(place)
            if let fetched, let data = fetched.image.jpegData(compressionQuality: 0.85) {
                try? data.write(to: folder.appendingPathComponent(key + ".jpg"))
                try? Data(fetched.credit.utf8).write(to: folder.appendingPathComponent(key + ".txt"))
                photos[place.itemID] = fetched
                trim(folder)
            } else {
                try? Data().write(to: folder.appendingPathComponent(key + ".none"))
            }
            // 잇달아 물으면 막힌다(429). 한 곳에 요청이 셋까지라 사이를 둔다.
            try? await Task.sleep(for: .milliseconds(1_200))
        }
    }

    private func readCache(_ key: String, in folder: URL) -> TravelPlacePhoto? {
        let file = folder.appendingPathComponent(key + ".jpg")
        guard let data = try? Data(contentsOf: file), let image = UIImage(data: data),
              let credit = try? String(contentsOf: folder.appendingPathComponent(key + ".txt"), encoding: .utf8), !credit.isEmpty else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        return TravelPlacePhoto(image: image, credit: credit)
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

    private func fetch(_ place: Place) async -> TravelPlacePhoto? {
        let language = TravelWikiPhoto.language(for: place.name)
        guard let found = await get(TravelWikiPhoto.searchURL(name: place.name, language: language)),
              let pick = TravelWikiPhoto.pick(found, name: place.name, latitude: place.latitude, longitude: place.longitude),
              let meta = await get(TravelWikiPhoto.creditURL(file: pick.file, language: language)), let credit = TravelWikiPhoto.credit(meta),
              let bytes = await get(pick.thumbnail), let image = UIImage(data: bytes) else { return nil }
        return TravelPlacePhoto(image: image, credit: credit)
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
