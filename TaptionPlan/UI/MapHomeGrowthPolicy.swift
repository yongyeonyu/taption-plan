import CoreLocation
import MapKit
import Observation
import OSLog
import SwiftUI
import UIKit
import TaptionPlanCore

struct MapHomeGrowthSeason: Codable, Equatable {
    var year: Int
    var level = 1
    var streak = 0
    var lastClosedDay: String?
    var pendingDay: String?
    var pendingDayQualified = false
    var pendingWeeklyRewards = 0
    var chosenEvolutions: [String] = []
    var landPlots: [String] = []
    var accessories: [String] = []
    var equippedHat: String?
    var equippedScarf: String?
    var equippedRibbon: String?
    var landPlotPlacements: [MapHomeGrowthPlotPlacement]?
    var recentCompletionRewardedDays: [String]?
    /// 그날을 닫았을 때의 레벨(GRW1105A01). 예전 저장본에는 없어 최초 1회 거꾸로 채운다.
    var dayLevels: [String: Int]?
}

extension MapHomeGrowthSeason {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        year = try c.decodeIfPresent(Int.self, forKey: .year)
            ?? Calendar(identifier: .gregorian).component(.year, from: .now)
        level = try c.decodeIfPresent(Int.self, forKey: .level) ?? 1
        streak = try c.decodeIfPresent(Int.self, forKey: .streak) ?? 0
        lastClosedDay = try c.decodeIfPresent(String.self, forKey: .lastClosedDay)
        pendingDay = try c.decodeIfPresent(String.self, forKey: .pendingDay)
        pendingDayQualified = try c.decodeIfPresent(Bool.self, forKey: .pendingDayQualified) ?? false
        pendingWeeklyRewards = try c.decodeIfPresent(Int.self, forKey: .pendingWeeklyRewards) ?? 0
        chosenEvolutions = try c.decodeIfPresent([String].self, forKey: .chosenEvolutions) ?? []
        landPlots = try c.decodeIfPresent([String].self, forKey: .landPlots) ?? []
        accessories = try c.decodeIfPresent([String].self, forKey: .accessories) ?? []
        equippedHat = try c.decodeIfPresent(String.self, forKey: .equippedHat)
        equippedScarf = try c.decodeIfPresent(String.self, forKey: .equippedScarf)
        equippedRibbon = try c.decodeIfPresent(String.self, forKey: .equippedRibbon)
        landPlotPlacements = try c.decodeIfPresent([MapHomeGrowthPlotPlacement].self, forKey: .landPlotPlacements)
        dayLevels = try c.decodeIfPresent([String: Int].self, forKey: .dayLevels)
        recentCompletionRewardedDays = try c.decodeIfPresent([String].self, forKey: .recentCompletionRewardedDays)
        // 착용 칸이 하나이던 때의 값을 그 장식의 종류 칸으로 옮긴다. 새 칸이 있으면 옛 값은 보지 않는다.
        if equippedHat == nil, equippedScarf == nil, equippedRibbon == nil,
           let legacy = try decoder.container(keyedBy: LegacyKeys.self).decodeIfPresent(String.self, forKey: .equippedAccessory) {
            setEquipped(legacy, kind: MapHomeGrowthAccessoryCatalog.kind(for: legacy))
        }
    }

    private enum LegacyKeys: String, CodingKey { case equippedAccessory }

    /// 착용한 장식 전체를 한 문자열로 나타낸 값. 지도·재생·영상까지 이 값 하나로 전달한다.
    /// 하나만 입었으면 그 장식 id와 같고, 아무것도 안 입었으면 nil이다.
    var equippedAccessory: String? {
        let worn = [equippedHat, equippedScarf, equippedRibbon].compactMap { $0 }
        return worn.isEmpty ? nil : worn.joined(separator: MapHomeGrowthAccessoryCatalog.outfitSeparator)
    }

    func equipped(_ kind: MapHomeAccessoryKind) -> String? {
        switch kind {
        case .hat: equippedHat
        case .scarf: equippedScarf
        case .ribbon: equippedRibbon
        }
    }

    func isEquipped(_ accessoryID: String) -> Bool {
        equipped(MapHomeGrowthAccessoryCatalog.kind(for: accessoryID)) == accessoryID
    }

    mutating func setEquipped(_ accessoryID: String, kind: MapHomeAccessoryKind) {
        switch kind {
        case .hat: equippedHat = accessoryID
        case .scarf: equippedScarf = accessoryID
        case .ribbon: equippedRibbon = accessoryID
        }
    }
}

/// 화랑이가 몸에 걸치는 장식 종류. 종류마다 하나씩 동시에 착용한다.
enum MapHomeAccessoryKind: String, CaseIterable {
    case hat, scarf, ribbon
}

struct MapHomeGrowthPlotPlacement: Codable, Equatable, Identifiable {
    let plotID: String
    let x: Int
    let y: Int

    var id: String { plotID }
}

struct MapHomeLandmarkCandidate: Identifiable, Equatable {
    let id: String
    let country: String
    let name: String
    let englishName: String
    let category: String
    let systemImage: String
    let accessoryKind: MapHomeAccessoryKind

    var artworkName: String {
        "Landmark_" + id.replacingOccurrences(of: ".", with: "_")
    }

    var accessoryID: String { "cat.accessory.\(id)" }
}

enum MapHomeLandmarkCatalog {
    static let candidates: [MapHomeLandmarkCandidate] = [
        .init(id: "kr.gyeongbokgung", country: "대한민국", name: "경복궁", englishName: "Gyeongbokgung", category: "건축", systemImage: "building.columns.fill", accessoryKind: .hat),
        .init(id: "kr.bulguksa", country: "대한민국", name: "불국사", englishName: "Bulguksa", category: "문화", systemImage: "building.2.fill", accessoryKind: .ribbon),
        .init(id: "kr.seongsan", country: "대한민국", name: "성산일출봉", englishName: "Seongsan Ilchulbong", category: "자연", systemImage: "mountain.2.fill", accessoryKind: .scarf),
        .init(id: "kr.haeundae", country: "대한민국", name: "해운대", englishName: "Haeundae", category: "자연", systemImage: "water.waves", accessoryKind: .ribbon),
        .init(id: "kr.hahoe", country: "대한민국", name: "하회마을", englishName: "Hahoe Folk Village", category: "문화", systemImage: "house.lodge.fill", accessoryKind: .scarf),
        // 한 해 주간 보상이 최대 52번이라 52개로 맞췄다. 두 곳은 그림 파일이 아직 없어 심볼로 보인다.
        .init(id: "kr.namsan", country: "대한민국", name: "N서울타워", englishName: "N Seoul Tower", category: "건축", systemImage: "antenna.radiowaves.left.and.right", accessoryKind: .hat),
        .init(id: "kr.hallasan", country: "대한민국", name: "한라산", englishName: "Hallasan", category: "자연", systemImage: "tree.fill", accessoryKind: .hat),
        .init(id: "jp.fuji", country: "일본", name: "후지산", englishName: "Mount Fuji", category: "자연", systemImage: "mountain.2.fill", accessoryKind: .hat),
        .init(id: "jp.himeji", country: "일본", name: "히메지성", englishName: "Himeji Castle", category: "건축", systemImage: "building.columns.fill", accessoryKind: .ribbon),
        .init(id: "jp.fushimi", country: "일본", name: "후시미 이나리", englishName: "Fushimi Inari", category: "문화", systemImage: "torii.gate.fill", accessoryKind: .hat),
        .init(id: "jp.itsukushima", country: "일본", name: "이쓰쿠시마 신사", englishName: "Itsukushima Shrine", category: "문화", systemImage: "water.waves", accessoryKind: .scarf),
        .init(id: "jp.arashiyama", country: "일본", name: "아라시야마", englishName: "Arashiyama", category: "자연", systemImage: "leaf.fill", accessoryKind: .scarf),
        .init(id: "us.liberty", country: "미국", name: "자유의 여신상", englishName: "Statue of Liberty", category: "건축", systemImage: "figure.stand", accessoryKind: .hat),
        .init(id: "us.grandcanyon", country: "미국", name: "그랜드 캐니언", englishName: "Grand Canyon", category: "자연", systemImage: "mountain.2.fill", accessoryKind: .hat),
        .init(id: "us.golden_gate", country: "미국", name: "금문교", englishName: "Golden Gate Bridge", category: "건축", systemImage: "bridge.fill", accessoryKind: .scarf),
        .init(id: "us.yosemite", country: "미국", name: "요세미티", englishName: "Yosemite", category: "자연", systemImage: "waterfall.fill", accessoryKind: .scarf),
        .init(id: "us.mount_rushmore", country: "미국", name: "러시모어산", englishName: "Mount Rushmore", category: "문화", systemImage: "mountain.2.fill", accessoryKind: .ribbon),
        .init(id: "gb.bigben", country: "영국", name: "빅벤", englishName: "Big Ben", category: "건축", systemImage: "clock.fill", accessoryKind: .hat),
        .init(id: "gb.stonehenge", country: "영국", name: "스톤헨지", englishName: "Stonehenge", category: "문화", systemImage: "circle.hexagongrid.fill", accessoryKind: .ribbon),
        .init(id: "gb.edinburgh", country: "영국", name: "에든버러성", englishName: "Edinburgh Castle", category: "건축", systemImage: "building.columns.fill", accessoryKind: .hat),
        .init(id: "gb.lake_district", country: "영국", name: "레이크 디스트릭트", englishName: "Lake District", category: "자연", systemImage: "water.waves", accessoryKind: .scarf),
        .init(id: "gb.tower_bridge", country: "영국", name: "타워 브리지", englishName: "Tower Bridge", category: "건축", systemImage: "bridge.fill", accessoryKind: .scarf),
        .init(id: "fr.eiffel", country: "프랑스", name: "에펠탑", englishName: "Eiffel Tower", category: "건축", systemImage: "tower.fill", accessoryKind: .hat),
        .init(id: "fr.mont_saint_michel", country: "프랑스", name: "몽생미셸", englishName: "Mont-Saint-Michel", category: "문화", systemImage: "building.columns.fill", accessoryKind: .ribbon),
        .init(id: "fr.louvre", country: "프랑스", name: "루브르 박물관", englishName: "Louvre Museum", category: "문화", systemImage: "building.columns.fill", accessoryKind: .scarf),
        .init(id: "fr.versailles", country: "프랑스", name: "베르사유 궁전", englishName: "Palace of Versailles", category: "건축", systemImage: "building.columns.fill", accessoryKind: .hat),
        .init(id: "fr.alps", country: "프랑스", name: "프랑스 알프스", englishName: "French Alps", category: "자연", systemImage: "mountain.2.fill", accessoryKind: .scarf),
        .init(id: "it.colosseum", country: "이탈리아", name: "콜로세움", englishName: "Colosseum", category: "건축", systemImage: "building.columns.fill", accessoryKind: .hat),
        .init(id: "it.venice", country: "이탈리아", name: "베네치아", englishName: "Venice", category: "문화", systemImage: "water.waves", accessoryKind: .hat),
        .init(id: "it.pisa", country: "이탈리아", name: "피사의 사탑", englishName: "Leaning Tower of Pisa", category: "건축", systemImage: "building.fill", accessoryKind: .ribbon),
        .init(id: "it.dolomites", country: "이탈리아", name: "돌로미티", englishName: "Dolomites", category: "자연", systemImage: "mountain.2.fill", accessoryKind: .ribbon),
        .init(id: "it.amalfi", country: "이탈리아", name: "아말피 해안", englishName: "Amalfi Coast", category: "자연", systemImage: "water.waves", accessoryKind: .scarf),
        .init(id: "cn.great_wall", country: "중국", name: "만리장성", englishName: "Great Wall", category: "건축", systemImage: "wall.3.fill", accessoryKind: .scarf),
        .init(id: "cn.forbidden_city", country: "중국", name: "자금성", englishName: "Forbidden City", category: "건축", systemImage: "building.columns.fill", accessoryKind: .hat),
        .init(id: "cn.zhangjiajie", country: "중국", name: "장자제", englishName: "Zhangjiajie", category: "자연", systemImage: "mountain.2.fill", accessoryKind: .ribbon),
        .init(id: "cn.terracotta", country: "중국", name: "병마용", englishName: "Terracotta Army", category: "문화", systemImage: "figure.stand", accessoryKind: .ribbon),
        .init(id: "cn.li_river", country: "중국", name: "리강", englishName: "Li River", category: "자연", systemImage: "water.waves", accessoryKind: .scarf),
        .init(id: "es.sagrada", country: "스페인", name: "사그라다 파밀리아", englishName: "Sagrada Família", category: "건축", systemImage: "building.columns.fill", accessoryKind: .hat),
        .init(id: "es.alhambra", country: "스페인", name: "알람브라", englishName: "Alhambra", category: "건축", systemImage: "building.columns.fill", accessoryKind: .ribbon),
        .init(id: "es.park_guell", country: "스페인", name: "구엘 공원", englishName: "Park Güell", category: "문화", systemImage: "leaf.fill", accessoryKind: .scarf),
        .init(id: "es.camino", country: "스페인", name: "산티아고 순례길", englishName: "Camino de Santiago", category: "문화", systemImage: "figure.walk", accessoryKind: .scarf),
        .init(id: "es.teide", country: "스페인", name: "테이데산", englishName: "Mount Teide", category: "자연", systemImage: "mountain.2.fill", accessoryKind: .ribbon),
        .init(id: "th.grand_palace", country: "태국", name: "왕궁", englishName: "Grand Palace", category: "건축", systemImage: "building.columns.fill", accessoryKind: .hat),
        .init(id: "th.phiphi", country: "태국", name: "피피섬", englishName: "Phi Phi Islands", category: "자연", systemImage: "water.waves", accessoryKind: .scarf),
        .init(id: "th.ayutthaya", country: "태국", name: "아유타야", englishName: "Ayutthaya", category: "문화", systemImage: "building.columns.fill", accessoryKind: .ribbon),
        .init(id: "th.doi_inthanon", country: "태국", name: "도이인타논", englishName: "Doi Inthanon", category: "자연", systemImage: "mountain.2.fill", accessoryKind: .ribbon),
        .init(id: "th.wat_arun", country: "태국", name: "왓 아룬", englishName: "Wat Arun", category: "건축", systemImage: "building.columns.fill", accessoryKind: .ribbon),
        .init(id: "au.opera", country: "호주", name: "시드니 오페라 하우스", englishName: "Sydney Opera House", category: "건축", systemImage: "building.columns.fill", accessoryKind: .ribbon),
        .init(id: "au.great_barrier", country: "호주", name: "그레이트 배리어 리프", englishName: "Great Barrier Reef", category: "자연", systemImage: "water.waves", accessoryKind: .scarf),
        .init(id: "au.uluru", country: "호주", name: "울루루", englishName: "Uluru", category: "문화", systemImage: "mountain.2.fill", accessoryKind: .hat),
        .init(id: "au.twelve_apostles", country: "호주", name: "12사도 바위", englishName: "Twelve Apostles", category: "자연", systemImage: "water.waves", accessoryKind: .ribbon),
        .init(id: "au.harbour_bridge", country: "호주", name: "시드니 하버 브리지", englishName: "Sydney Harbour Bridge", category: "건축", systemImage: "bridge.fill", accessoryKind: .ribbon),
    ]

    /// 이번 시즌에 52개를 다 골랐는지. 다 고르면 주간 보상을 더 받지 않는다(대표 지시, ACC1102A01).
    static func isCollectionComplete(_ season: MapHomeGrowthSeason) -> Bool {
        let chosen = Set(season.chosenEvolutions)
        return !candidates.isEmpty && candidates.allSatisfy { chosen.contains($0.id) }
    }

    /// 이번 시즌에 이미 고른 랜드마크는 후보에서 뺀다. 다 모으면 후보가 없다.
    static func weeklyChoices(for season: MapHomeGrowthSeason) -> [MapHomeLandmarkCandidate] {
        let chosen = Set(season.chosenEvolutions)
        let pool = candidates.filter { !chosen.contains($0.id) }
        guard !pool.isEmpty else { return [] }
        let start = (season.year &+ season.chosenEvolutions.count * 3) % pool.count
        return (0..<min(3, pool.count)).map {
            pool[(start + $0) % pool.count]
        }
    }
}

enum MapHomeGrowthAccessoryCatalog {
    private static let symbols = [
        "crown.fill", "sparkles", "leaf.fill", "sun.max.fill", "flower.fill",
    ]

    /// 장식이 따온 랜드마크. 장식 id는 `cat.accessory.<랜드마크 id>`다.
    static func landmark(for accessoryID: String?) -> MapHomeLandmarkCandidate? {
        guard let accessoryID, !accessoryID.isEmpty else { return nil }
        return MapHomeLandmarkCatalog.candidates.first { $0.accessoryID == accessoryID }
    }

    /// 장식 종류. 옛 장식 id처럼 랜드마크를 못 찾으면 예전대로 머리 칸에 둔다.
    static func kind(for accessoryID: String) -> MapHomeAccessoryKind {
        landmark(for: accessoryID)?.accessoryKind ?? .hat
    }

    /// 도감과 목록에 쓰는 장식 그림. 옛 장식 id처럼 랜드마크를 못 찾으면 nil이다.
    static func artworkName(for accessoryID: String?) -> String? {
        landmark(for: accessoryID).map { landmark in
            let prefix = switch landmark.accessoryKind {
            case .hat: "Hat_"
            case .scarf: "Scarf_"
            case .ribbon: "Ribbon_"
            }
            return prefix + landmark.id.replacingOccurrences(of: ".", with: "_")
        }
    }

    static let outfitSeparator = "+"

    /// 착용 값(`MapHomeGrowthSeason.equippedAccessory`)에서 종류별 장식을 찾는다. 장식 id 하나도 그대로 받는다.
    private static func worn(_ kind: MapHomeAccessoryKind, in outfit: String?) -> MapHomeLandmarkCandidate? {
        guard let outfit else { return nil }
        return outfit.components(separatedBy: outfitSeparator).lazy
            .compactMap { landmark(for: $0) }
            .first { $0.accessoryKind == kind }
    }

    /// 화랑이 머리에 쓰는 모자 그림(ACC1101A01). 모자를 안 썼으면 nil이다.
    static func hatAssetName(for outfit: String?) -> String? {
        artworkName(for: worn(.hat, in: outfit)?.accessoryID)
    }

    static func scarfStyle(for outfit: String?) -> HwarangClothStyle? {
        worn(.scarf, in: outfit).flatMap { HwarangClothStyle.byLandmark[$0.id] }
    }

    static func ribbonStyle(for outfit: String?) -> HwarangClothStyle? {
        worn(.ribbon, in: outfit).flatMap { HwarangClothStyle.byLandmark[$0.id] }
    }

    /// 화랑이 아이콘에 달리는 무늬. 랜드마크 장식은 그 랜드마크의 심볼(건축·자연·문화)을 쓰고,
    /// 옛 장식 id처럼 랜드마크를 못 찾으면 예전처럼 id로 고른 기본 심볼을 쓴다.
    static func symbol(for accessoryID: String?) -> String? {
        guard let accessoryID, !accessoryID.isEmpty else { return nil }
        if let landmark = landmark(for: accessoryID) { return landmark.systemImage }
        let index = accessoryID.utf8.reduce(0) { ($0 + Int($1)) % symbols.count }
        return symbols[index]
    }
}

/// The growth history is read many times per body pass (every marker and the
/// playback marker), so decode the stored JSON once per stored value.
@MainActor
final class MapHomeGrowthHistoryCache {
    private var data: Data?
    /// 실패한 디코딩도 캐시한다. 빈 데이터(새 사용자)마다 디코더를 다시 만들지 않게 한다.
    private var decoded: MapHomeGrowthHistory?

    func history(for data: Data) -> MapHomeGrowthHistory? {
        if self.data == data { return decoded }
        self.data = data
        decoded = try? JSONDecoder().decode(MapHomeGrowthHistory.self, from: data)
        return decoded
    }
}

/// Header date text is rebuilt on every invalidation; DateFormatter creation
/// is expensive, so reuse one per format and locale.
@MainActor
enum MapHomeDateText {
    private static var formatters: [String: DateFormatter] = [:]

    static func string(from date: Date, format: String, locale: Locale) -> String {
        let key = "\(locale.identifier)|\(format)"
        let formatter: DateFormatter
        if let cached = formatters[key] {
            formatter = cached
        } else {
            formatter = DateFormatter()
            formatter.locale = locale
            formatter.dateFormat = format
            formatters[key] = formatter
        }
        formatter.timeZone = .autoupdatingCurrent
        return formatter.string(from: date)
    }
}

struct MapHomeGrowthHistory: Codable, Equatable {
    var season: MapHomeGrowthSeason
    var archives: [MapHomeGrowthSeason] = []

    init(season: MapHomeGrowthSeason, archives: [MapHomeGrowthSeason] = []) {
        self.season = season
        self.archives = archives
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        season = try c.decode(MapHomeGrowthSeason.self, forKey: .season)
        archives = try c.decodeIfPresent([MapHomeGrowthSeason].self, forKey: .archives) ?? []
    }

    static func initial(for date: Date, calendar: Calendar = Calendar(identifier: .gregorian)) -> Self {
        Self(season: MapHomeGrowthSeason(year: calendar.component(.year, from: date)))
    }
}

enum MapHomeGrowthPolicy {
    static let storageKey = "taption.mapHome.growth.v1"

    static var localCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        return calendar
    }

    /// 주간 보상은 연속 달성 7일마다 한 번. 7일 단위로 남은 일수(1~7)를 돌려준다.
    static func daysUntilNextWeeklyReward(streak: Int) -> Int {
        7 - max(0, streak) % 7
    }

    static func qualifies(actualCount: Int, unconfirmedCount: Int) -> Bool {
        actualCount > 0 && unconfirmedCount == 0
    }

    static func qualifiesDay(
        actuals: [ActualRecord],
        travel: [TravelSegment],
        on date: Date,
        asOf now: Date,
        calendar: Calendar
    ) -> Bool {
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start)
            ?? start.addingTimeInterval(86_400)
        let actualCount = actuals.filter {
            let span = $0.span(asOf: now)
            return span.start < end && start < span.end
                && RecordAnalysisCategoryPolicy.categoryID(for: $0) != "unconfirmed"
        }.count
        let unconfirmedCount = MapHomeTimeRailSegmentEngine.segments(
            from: actuals,
            travel: travel,
            on: date,
            asOf: now,
            calendar: calendar
        ).filter { $0.categoryID == "unconfirmed" }.count
        return qualifies(actualCount: actualCount, unconfirmedCount: unconfirmedCount)
    }

    static func maximumLevel(year: Int, timeZone: TimeZone = .autoupdatingCurrent) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = timeZone
        components.year = year
        components.month = 7
        components.day = 1
        guard let date = calendar.date(from: components),
              let days = calendar.range(of: .day, in: .year, for: date)?.count else {
            return 365
        }
        return days
    }

    /// "우리집 (경복궁)". 그날의 집이 무슨 건물인지 함께 적는다.
    static func homeTitle(level: Int, language: MapHomeLanguage) -> String {
        let name = homeName(level: level, language: language)
        return language.text("우리집 (\(name))", "Our home (\(name))")
    }

    static func homeName(level: Int, language: MapHomeLanguage) -> String {
        let name = MapHomeHomeNames.names[min(max(level, 1), MapHomeHomeNames.names.count) - 1]
        return language.runtimeText(name.korean, name.english)
    }

    static func artworkName(level: Int) -> String {
        let paddedLevel = String(
            format: "%03d",
            locale: Locale(identifier: "en_US_POSIX"),
            min(max(level, 1), 366)
        )
        return "HomeEvolution\(paddedLevel)"
    }

    static func isLeapDay(_ date: Date, calendar: Calendar) -> Bool {
        let components = calendar.dateComponents([.month, .day], from: date)
        return components.month == 2 && components.day == 29
    }

    static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            locale: Locale(identifier: "en_US_POSIX"),
            parts.year ?? 0,
            parts.month ?? 0,
            parts.day ?? 0
        )
    }

    static func date(for key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(
            year: parts[0], month: parts[1], day: parts[2]
        ))
    }

    static func closePendingDay(
        in history: inout MapHomeGrowthHistory,
        asOf now: Date,
        calendar: Calendar
    ) {
        let today = calendar.startOfDay(for: now)
        guard let key = history.season.pendingDay,
              let pendingDate = date(for: key, calendar: calendar),
              calendar.startOfDay(for: pendingDate) < today else { return }
        closeDay(
            key: key,
            date: pendingDate,
            qualified: history.season.pendingDayQualified,
            in: &history,
            calendar: calendar
        )
        history.season.pendingDay = nil
        history.season.pendingDayQualified = false
    }

    static func observeCurrentDay(
        in history: inout MapHomeGrowthHistory,
        date: Date,
        qualified: Bool,
        calendar: Calendar
    ) {
        let year = calendar.component(.year, from: date)
        advanceSeason(in: &history, to: year)
        let key = dayKey(date, calendar: calendar)
        history.season.pendingDay = key
        history.season.pendingDayQualified = qualified
    }

    @discardableResult
    static func awardRecentCompletion(
        in history: inout MapHomeGrowthHistory,
        day: Date,
        asOf now: Date,
        qualified: Bool,
        calendar: Calendar
    ) -> Bool {
        let dayStart = calendar.startOfDay(for: day)
        let today = calendar.startOfDay(for: now)
        guard qualified,
              let distance = calendar.dateComponents([.day], from: dayStart, to: today).day,
              (1...7).contains(distance) else { return false }
        let key = dayKey(day, calendar: calendar)
        let year = calendar.component(.year, from: day)
        if history.season.year == year {
            return awardRecentCompletion(key: key, in: &history.season, calendar: calendar)
        }
        guard let index = history.archives.firstIndex(where: { $0.year == year }) else {
            return false
        }
        return awardRecentCompletion(key: key, in: &history.archives[index], calendar: calendar)
    }

    static func settleAndAwardRecentCompletion(
        in history: inout MapHomeGrowthHistory,
        day: Date,
        asOf now: Date,
        qualified: Bool,
        calendar: Calendar
    ) {
        closePendingDay(in: &history, asOf: now, calendar: calendar)
        awardRecentCompletion(
            in: &history,
            day: day,
            asOf: now,
            qualified: qualified,
            calendar: calendar
        )
    }

    private static func awardRecentCompletion(
        key: String,
        in season: inout MapHomeGrowthSeason,
        calendar: Calendar
    ) -> Bool {
        var rewardedDays = season.recentCompletionRewardedDays ?? []
        guard !rewardedDays.contains(key) else { return false }
        rewardedDays.append(key)
        season.recentCompletionRewardedDays = rewardedDays
        season.level = min(
            maximumLevel(year: season.year, timeZone: calendar.timeZone),
            season.level + 1
        )
        season.dayLevels = (season.dayLevels ?? [:]).merging([key: season.level]) { _, new in new }
        return true
    }

    /// 그날의 집 레벨. 아직 닫지 않은 날은 지금 레벨이고, 기록이 없는 시즌은 nil이다.
    static func level(on day: Date, in history: MapHomeGrowthHistory, calendar: Calendar) -> Int? {
        let key = dayKey(day, calendar: calendar)
        let year = calendar.component(.year, from: day)
        guard let season = ([history.season] + history.archives).first(where: { $0.year == year }) else { return nil }
        if season.lastClosedDay.map({ key > $0 }) ?? true { return season.level }
        guard let levels = season.dayLevels, !levels.isEmpty else { return nil }
        if let exact = levels[key] { return exact }
        // 앱이 닫지 못한 날은 그 앞 날의 레벨을 잇고, 기록보다 앞선 날은 시즌 시작 레벨이다.
        return levels.keys.filter { $0 < key }.max().flatMap { levels[$0] } ?? 1
    }

    /// 날짜별 기록이 없는 저장본을 지금 레벨에서 거꾸로 채운다. 달성한 날마다 1씩 올랐다고 본다.
    static func backfillDayLevelsIfNeeded(
        in history: inout MapHomeGrowthHistory,
        calendar: Calendar,
        qualifies: (Date) -> Bool
    ) {
        guard history.season.dayLevels == nil,
              let last = history.season.lastClosedDay,
              var day = date(for: last, calendar: calendar) else { return }
        var levels: [String: Int] = [:]
        var level = history.season.level
        while level > 1, calendar.component(.year, from: day) == history.season.year {
            levels[dayKey(day, calendar: calendar)] = level
            if qualifies(day) { level -= 1 }
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        history.season.dayLevels = levels
    }

    @discardableResult
    static func redeemWeeklyReward(
        evolutionID: String,
        landPlotID: String,
        accessoryID: String,
        in history: inout MapHomeGrowthHistory
    ) -> Bool {
        guard history.season.pendingWeeklyRewards > 0,
              !MapHomeLandmarkCatalog.isCollectionComplete(history.season),
              !evolutionID.isEmpty,
              !landPlotID.isEmpty,
              !accessoryID.isEmpty else { return false }
        history.season.pendingWeeklyRewards -= 1
        history.season.chosenEvolutions.append(evolutionID)
        history.season.landPlots.append(landPlotID)
        if !history.season.accessories.contains(accessoryID) {
            history.season.accessories.append(accessoryID)
        }
        if MapHomeLandmarkCatalog.isCollectionComplete(history.season) {
            history.season.pendingWeeklyRewards = 0
        }
        return true
    }

    @discardableResult
    static func equipAccessory(
        _ accessoryID: String,
        in season: inout MapHomeGrowthSeason
    ) -> Bool {
        guard season.accessories.contains(accessoryID) else { return false }
        season.setEquipped(accessoryID, kind: MapHomeGrowthAccessoryCatalog.kind(for: accessoryID))
        return true
    }

    /// 땅 조각을 붙일 수 있는 빈 칸: 이미 놓인 땅과 변을 맞댄 칸. 아직 아무것도 없으면 (0,0)(집 자리).
    static func placementCandidates(in season: MapHomeGrowthSeason) -> [(x: Int, y: Int)] {
        let placements = season.landPlotPlacements ?? []
        guard !placements.isEmpty else { return [(0, 0)] }
        let occupied = Set(placements.map { "\($0.x),\($0.y)" })
        var seen = Set<String>()
        var result: [(x: Int, y: Int)] = []
        for placement in placements {
            for (dx, dy) in [(1, 0), (0, 1), (-1, 0), (0, -1)] {
                let x = placement.x + dx, y = placement.y + dy
                let key = "\(x),\(y)"
                if !occupied.contains(key), seen.insert(key).inserted { result.append((x, y)) }
            }
        }
        return result
    }

    /// 사용자가 고른 칸에 땅 조각을 붙인다. 붙일 수 있는 빈 칸이 아니면 false.
    @discardableResult
    static func placeLandPlot(
        _ plotID: String,
        atX x: Int,
        y: Int,
        in season: inout MapHomeGrowthSeason
    ) -> Bool {
        guard season.landPlots.contains(plotID),
              !(season.landPlotPlacements ?? []).contains(where: { $0.plotID == plotID }),
              placementCandidates(in: season).contains(where: { $0.x == x && $0.y == y }) else { return false }
        var placements = season.landPlotPlacements ?? []
        placements.append(.init(plotID: plotID, x: x, y: y))
        season.landPlotPlacements = placements
        return true
    }

    @discardableResult
    static func placeLandPlot(
        _ plotID: String,
        in season: inout MapHomeGrowthSeason
    ) -> Bool {
        guard season.landPlots.contains(plotID) else { return false }
        var placements = season.landPlotPlacements ?? []
        guard !placements.contains(where: { $0.plotID == plotID }) else {
            return false
        }
        if placements.isEmpty {
            placements.append(.init(plotID: plotID, x: 0, y: 0))
            season.landPlotPlacements = placements
            return true
        }
        let occupied = Set(placements.map { "\($0.x),\($0.y)" })
        let directions = [(1, 0), (0, 1), (-1, 0), (0, -1)]
        for anchor in placements.reversed() {
            for (dx, dy) in directions {
                let x = anchor.x + dx
                let y = anchor.y + dy
                guard !occupied.contains("\(x),\(y)") else { continue }
                placements.append(.init(plotID: plotID, x: x, y: y))
                season.landPlotPlacements = placements
                return true
            }
        }
        return false
    }

    private static func closeDay(
        key: String,
        date: Date,
        qualified: Bool,
        in history: inout MapHomeGrowthHistory,
        calendar: Calendar
    ) {
        advanceSeason(in: &history, to: calendar.component(.year, from: date))
        guard history.season.lastClosedDay != key else { return }
        let previousDay = calendar.date(byAdding: .day, value: -1, to: date)
            .map { dayKey($0, calendar: calendar) }
        if history.season.lastClosedDay != previousDay {
            history.season.streak = 0
        }
        if qualified {
            history.season.level = min(
                maximumLevel(year: history.season.year, timeZone: calendar.timeZone),
                history.season.level + 1
            )
            history.season.streak += 1
            if history.season.streak.isMultiple(of: 7), !MapHomeLandmarkCatalog.isCollectionComplete(history.season) {
                history.season.pendingWeeklyRewards += 1
            }
            var rewardedDays = history.season.recentCompletionRewardedDays ?? []
            if !rewardedDays.contains(key) {
                rewardedDays.append(key)
                history.season.recentCompletionRewardedDays = rewardedDays
            }
        } else {
            history.season.streak = 0
        }
        history.season.lastClosedDay = key
        history.season.dayLevels = (history.season.dayLevels ?? [:]).merging([key: history.season.level]) { _, new in new }
    }

    private static func advanceSeason(in history: inout MapHomeGrowthHistory, to year: Int) {
        guard year > history.season.year else { return }
        history.archives.append(history.season)
        history.season = MapHomeGrowthSeason(year: year)
    }
}
