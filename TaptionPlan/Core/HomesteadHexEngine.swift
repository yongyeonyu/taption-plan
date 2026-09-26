import CoreLocation
import Foundation

// "탐험지 개척(Homestead)" 게임의 순수 엔진. 좌표 변환·하루 완성 판정·보상
// 계산을 UI/센서와 분리해 매크로 없이 단위테스트 가능하게 둔다. 자동 기록
// 원본은 절대 건드리지 않는다 — 여기서 다루는 것은 전부 파생 게임 상태다.

/// axial(q,r) 육각 좌표. pointy-top 배치. 집이 원점(0,0).
struct HexCoord: Hashable, Codable, Sendable {
    let q: Int
    let r: Int

    init(_ q: Int, _ r: Int) {
        self.q = q
        self.r = r
    }

    static let origin = HexCoord(0, 0)

    /// 인접 6방향(pointy-top axial 이웃).
    static let neighborDirections: [HexCoord] = [
        HexCoord(1, 0), HexCoord(1, -1), HexCoord(0, -1),
        HexCoord(-1, 0), HexCoord(-1, 1), HexCoord(0, 1),
    ]

    var neighbors: [HexCoord] {
        Self.neighborDirections.map { HexCoord(q + $0.q, r + $0.r) }
    }

    /// 원점(집)으로부터의 hex 거리(ring 수).
    var ringDistance: Int {
        (abs(q) + abs(q + r) + abs(r)) / 2
    }
}

/// hex 타일 바이옴(꾸미기). 안개=미개척, 그 외=개척된 지형.
enum HexBiome: String, Codable, CaseIterable, Sendable {
    case fog       // 미개척(안개)
    case meadow    // 초원(기본 개간)
    case forest    // 숲
    case water     // 호수
    case mountain  // 산

    /// 개간 코인 비용(기본 개간=meadow, 그 외 테마는 추가 비용).
    var clearCost: Int {
        switch self {
        case .fog: 0
        case .meadow: 3
        case .forest: 5
        case .water: 5
        case .mountain: 8
        }
    }
}

/// 하루 키(로컬 자정 기준 yyyy-MM-dd). 완주일 집합·스트릭 계산에 사용.
struct HomesteadDayKey: Hashable, Codable, Comparable, Sendable {
    let value: String

    static func < (lhs: HomesteadDayKey, rhs: HomesteadDayKey) -> Bool {
        lhs.value < rhs.value
    }

    static func make(_ date: Date, calendar: Calendar = .current) -> HomesteadDayKey {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return HomesteadDayKey(
            value: String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        )
    }

    /// 전날 키(스트릭 연속성 판정용).
    func previous(calendar: Calendar = .current) -> HomesteadDayKey? {
        let f = DateFormatter()
        f.calendar = calendar
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = calendar.timeZone
        f.dateFormat = "yyyy-MM-dd"
        guard let date = f.date(from: value),
              let prev = calendar.date(byAdding: .day, value: -1, to: date)
        else { return nil }
        return HomesteadDayKey(value: f.string(from: prev))
    }
}

/// 저장되는 게임 상태 전체. Codable JSON으로 App Group UserDefaults에 보관.
struct HomesteadState: Codable, Equatable, Sendable {
    var coins: Int = 0
    var ownedHexes: Set<HexCoord> = [.origin]          // 집 타일은 기본 보유
    var hexBiomes: [String: HexBiome] = ["0,0": .meadow] // key=HexCoord.storageKey
    var completedDays: Set<String> = []                 // HomesteadDayKey.value
    var currentStreak: Int = 0
    var bestStreak: Int = 0
    var lastRewardedDay: String?                        // 이중지급 방지

    static let empty = HomesteadState()

    func biome(at hex: HexCoord) -> HexBiome {
        hexBiomes[hex.storageKey] ?? .fog
    }

    func owns(_ hex: HexCoord) -> Bool { ownedHexes.contains(hex) }
}

extension HexCoord {
    /// Dictionary 저장용 문자열 키(Codable에서 HexCoord 키 직렬화 회피).
    var storageKey: String { "\(q),\(r)" }

    init?(storageKey: String) {
        let parts = storageKey.split(separator: ",")
        guard parts.count == 2, let q = Int(parts[0]), let r = Int(parts[1])
        else { return nil }
        self.init(q, r)
    }
}

/// 하루 완성 판정 결과.
struct HomesteadDayCompletion: Equatable, Sendable {
    let isComplete: Bool
    let unconfirmedSeconds: Double
    let observedSeconds: Double

    var confirmedRatio: Double {
        guard observedSeconds > 0 else { return 0 }
        return max(0, min(1, (observedSeconds - unconfirmedSeconds) / observedSeconds))
    }
}

/// 하루 완주 시 지급 보상 내역.
struct HomesteadReward: Equatable, Sendable {
    let baseCoins: Int          // questStats 비례 부분 보상
    let completionBonus: Int    // 미확인 0 완주 보너스
    let streakMultiplierX10: Int // 스트릭 배수 x10 (정수화)
    var totalCoins: Int {
        Int((Double(baseCoins + completionBonus) * Double(streakMultiplierX10) / 10).rounded())
    }
}

enum HomesteadHexEngine {
    /// hex 한 변 길이(미터). 집 자주가는장소 기본 반경과 정합.
    static let hexEdgeMeters: Double = 120

    // MARK: - 좌표 변환 (geo <-> hex)

    /// 위경도를 집 원점 기준 평면(동/북 미터)으로 근사 투영한다.
    /// 소규모(수 km) 반경에서 충분히 정확한 equirectangular 근사.
    static func localMeters(
        of coordinate: CLLocationCoordinate2D,
        home: CLLocationCoordinate2D
    ) -> (east: Double, north: Double) {
        let earth = 6_378_137.0
        let latRad = home.latitude * .pi / 180
        let dLat = (coordinate.latitude - home.latitude) * .pi / 180
        let dLon = (coordinate.longitude - home.longitude) * .pi / 180
        let north = dLat * earth
        let east = dLon * earth * cos(latRad)
        return (east, north)
    }

    /// 집 원점 기준 평면 미터를 위경도로 되돌린다.
    static func coordinate(
        eastMeters east: Double,
        northMeters north: Double,
        home: CLLocationCoordinate2D
    ) -> CLLocationCoordinate2D {
        let earth = 6_378_137.0
        let latRad = home.latitude * .pi / 180
        let dLat = north / earth
        let dLon = east / (earth * cos(latRad))
        return CLLocationCoordinate2D(
            latitude: home.latitude + dLat * 180 / .pi,
            longitude: home.longitude + dLon * 180 / .pi
        )
    }

    /// pointy-top hex 중심의 평면 미터 좌표.
    private static func hexCenterMeters(_ hex: HexCoord) -> (east: Double, north: Double) {
        let size = hexEdgeMeters
        let east = size * (3.0.squareRoot() * Double(hex.q) + 3.0.squareRoot() / 2 * Double(hex.r))
        let north = size * (1.5 * Double(hex.r))
        return (east, north)
    }

    /// hex 중심의 위경도.
    static func center(of hex: HexCoord, home: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        let m = hexCenterMeters(hex)
        return coordinate(eastMeters: m.east, northMeters: m.north, home: home)
    }

    /// 임의 좌표가 속한 hex(반올림 포함).
    static func hex(
        for coordinate: CLLocationCoordinate2D,
        home: CLLocationCoordinate2D
    ) -> HexCoord {
        let m = localMeters(of: coordinate, home: home)
        let size = hexEdgeMeters
        let qf = (3.0.squareRoot() / 3 * m.east - 1.0 / 3 * m.north) / size
        let rf = (2.0 / 3 * m.north) / size
        return axialRound(qf: qf, rf: rf)
    }

    /// 분수 axial 좌표를 가장 가까운 정수 hex로 반올림(cube round 경유).
    static func axialRound(qf: Double, rf: Double) -> HexCoord {
        let xf = qf
        let zf = rf
        let yf = -xf - zf
        var rx = xf.rounded()
        var ry = yf.rounded()
        var rz = zf.rounded()
        let dx = abs(rx - xf)
        let dy = abs(ry - yf)
        let dz = abs(rz - zf)
        if dx > dy && dx > dz {
            rx = -ry - rz
        } else if dy > dz {
            ry = -rx - rz
        } else {
            rz = -rx - ry
        }
        return HexCoord(Int(rx), Int(rz))
    }

    /// 원점 기준 반경 `radius` ring 안의 모든 hex(뷰포트 컬링 전 후보).
    static func hexes(withinRings radius: Int) -> [HexCoord] {
        guard radius >= 0 else { return [] }
        var result: [HexCoord] = []
        for q in -radius...radius {
            let rMin = max(-radius, -q - radius)
            let rMax = min(radius, -q + radius)
            for r in rMin...rMax {
                result.append(HexCoord(q, r))
            }
        }
        return result
    }

    // MARK: - 하루 완성 판정

    /// 하루의 미확인(gap) 총 시간으로 완주 여부를 판정한다. `unconfirmedSeconds`는
    /// 호출부가 `ReviewCoverageEngine.unconfirmedRecords`로 계산해 전달한다(원본 불변).
    /// 관용 임계(기본 5분) 이하면 완주로 본다.
    static func completion(
        unconfirmedSeconds: Double,
        observedSeconds: Double,
        toleranceSeconds: Double = 300
    ) -> HomesteadDayCompletion {
        let complete = observedSeconds > 0 && unconfirmedSeconds <= toleranceSeconds
        return HomesteadDayCompletion(
            isComplete: complete,
            unconfirmedSeconds: max(0, unconfirmedSeconds),
            observedSeconds: max(0, observedSeconds)
        )
    }

    // MARK: - 보상 계산

    /// 부분 보상(거리·장소·활동종류 비례) + 완주 보너스 + 스트릭 배수.
    static func reward(
        distanceMeters: Double,
        placeCount: Int,
        activityKinds: Int,
        completion: HomesteadDayCompletion,
        streak: Int
    ) -> HomesteadReward {
        let distanceCoins = Int((distanceMeters / 1000).rounded())      // 1km = 1코인
        let placeCoins = placeCount                                      // 장소당 1코인
        let kindCoins = activityKinds                                    // 활동종류당 1코인
        let base = distanceCoins + placeCoins + kindCoins
        let bonus = completion.isComplete ? 10 : 0                       // 완주 보너스
        // 스트릭 배수: 1일=1.0x, 매 연속일 +0.1x, 최대 2.0x.
        let multX10 = completion.isComplete
            ? min(20, 10 + max(0, streak - 1))
            : 10
        return HomesteadReward(
            baseCoins: base,
            completionBonus: bonus,
            streakMultiplierX10: multX10
        )
    }

    // MARK: - 상태 전이 (하루 정산)

    /// 하루를 정산해 코인·스트릭·완주일·보유 hex를 갱신한 새 상태를 돌려준다.
    /// 같은 날 중복 지급을 막고, 완주면 스트릭을 잇거나 시작한다.
    /// 순수 함수 — 입력 상태를 변형하지 않는다.
    static func settleDay(
        _ state: HomesteadState,
        dayKey: HomesteadDayKey,
        completion: HomesteadDayCompletion,
        distanceMeters: Double,
        placeCount: Int,
        activityKinds: Int,
        calendar: Calendar = .current
    ) -> (state: HomesteadState, reward: HomesteadReward) {
        var next = state
        // 이미 정산한 날이면 코인만 재계산하지 않고 그대로 반환(이중지급 방지).
        if next.lastRewardedDay == dayKey.value {
            return (next, HomesteadReward(baseCoins: 0, completionBonus: 0, streakMultiplierX10: 10))
        }

        // 스트릭: 완주 시, 전날도 완주였으면 +1, 아니면 1로 시작. 미완주면 0.
        if completion.isComplete {
            let prevKey = dayKey.previous(calendar: calendar)?.value
            let continues = prevKey.map { next.completedDays.contains($0) } ?? false
            next.currentStreak = continues ? next.currentStreak + 1 : 1
            next.bestStreak = max(next.bestStreak, next.currentStreak)
            next.completedDays.insert(dayKey.value)
        } else {
            next.currentStreak = 0
        }

        let reward = reward(
            distanceMeters: distanceMeters,
            placeCount: placeCount,
            activityKinds: activityKinds,
            completion: completion,
            streak: next.currentStreak
        )
        next.coins += reward.totalCoins
        next.lastRewardedDay = dayKey.value
        return (next, reward)
    }

    // MARK: - 타일 개간

    /// 인접(보유 hex에 맞닿은) 미보유 hex만 개간 가능. 코인이 충분하면 개간.
    /// 순수 함수 — 실패 시 원 상태와 사유를 반환.
    static func clear(
        _ state: HomesteadState,
        hex: HexCoord,
        biome: HexBiome = .meadow
    ) -> (state: HomesteadState, ok: Bool, reason: ClearFailure?) {
        guard !state.owns(hex) else { return (state, false, .alreadyOwned) }
        guard isAdjacentToOwned(hex, in: state) else { return (state, false, .notAdjacent) }
        let cost = max(biome.clearCost, HexBiome.meadow.clearCost)
        guard state.coins >= cost else { return (state, false, .insufficientCoins(cost)) }
        var next = state
        next.coins -= cost
        next.ownedHexes.insert(hex)
        next.hexBiomes[hex.storageKey] = biome
        return (next, true, nil)
    }

    /// 이미 보유한 hex의 바이옴(테마)을 코인으로 바꾼다.
    static func decorate(
        _ state: HomesteadState,
        hex: HexCoord,
        biome: HexBiome
    ) -> (state: HomesteadState, ok: Bool, reason: ClearFailure?) {
        guard state.owns(hex) else { return (state, false, .notAdjacent) }
        let cost = biome.clearCost
        guard state.coins >= cost else { return (state, false, .insufficientCoins(cost)) }
        var next = state
        next.coins -= cost
        next.hexBiomes[hex.storageKey] = biome
        return (next, true, nil)
    }

    static func isAdjacentToOwned(_ hex: HexCoord, in state: HomesteadState) -> Bool {
        hex.neighbors.contains { state.owns($0) }
    }

    enum ClearFailure: Equatable, Sendable {
        case alreadyOwned
        case notAdjacent
        case insufficientCoins(Int)
    }
}
