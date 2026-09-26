import Foundation
import TaptionPlanCore

// 게임 상태 영속·발행 저장소. AppLanguagePreference 와 동일하게 App Group
// UserDefaults 에 JSON 으로 보관한다(파생 게임 상태 전용, 자동기록 원본과 분리).
// 위젯/워치는 이 상태를 쓰지 않으므로 앱 프로세스 안에서만 다룬다.
@MainActor
final class HomesteadStore: ObservableObject {
    static let appGroupIdentifier = TaptionPlanSharedContainer.appGroupIdentifier
    static let storageKey = "taption.homestead.state.v1"

    @Published private(set) var state: HomesteadState

    private let defaults: UserDefaults

    init(defaults: UserDefaults? = nil) {
        let store = defaults
            ?? UserDefaults(suiteName: Self.appGroupIdentifier)
            ?? .standard
        self.defaults = store
        self.state = Self.load(from: store)
    }

    static func load(from defaults: UserDefaults) -> HomesteadState {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(HomesteadState.self, from: data)
        else { return .empty }
        return decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    // MARK: - 하루 정산

    /// 하루를 정산해 코인·스트릭·완주일을 갱신한다. 같은 날 재호출은 무시(이중지급 방지).
    /// 반환값은 이번 지급 보상(0이면 이미 정산됨 또는 미완주 부분보상 없음).
    @discardableResult
    func settleDay(
        date: Date,
        completion: HomesteadDayCompletion,
        distanceMeters: Double,
        placeCount: Int,
        activityKinds: Int,
        calendar: Calendar = .current
    ) -> HomesteadReward {
        let key = HomesteadDayKey.make(date, calendar: calendar)
        let result = HomesteadHexEngine.settleDay(
            state,
            dayKey: key,
            completion: completion,
            distanceMeters: distanceMeters,
            placeCount: placeCount,
            activityKinds: activityKinds,
            calendar: calendar
        )
        state = result.state
        persist()
        return result.reward
    }

    // MARK: - 타일 개간/꾸미기

    @discardableResult
    func clear(hex: HexCoord, biome: HexBiome = .meadow) -> Bool {
        let result = HomesteadHexEngine.clear(state, hex: hex, biome: biome)
        guard result.ok else { return false }
        state = result.state
        persist()
        return true
    }

    @discardableResult
    func decorate(hex: HexCoord, biome: HexBiome) -> Bool {
        let result = HomesteadHexEngine.decorate(state, hex: hex, biome: biome)
        guard result.ok else { return false }
        state = result.state
        persist()
        return true
    }

    // MARK: - 조회

    var coins: Int { state.coins }
    var streak: Int { state.currentStreak }
    var bestStreak: Int { state.bestStreak }

    func owns(_ hex: HexCoord) -> Bool { state.owns(hex) }
    func biome(at hex: HexCoord) -> HexBiome { state.biome(at: hex) }
    func canClear(_ hex: HexCoord) -> Bool {
        !state.owns(hex) && HomesteadHexEngine.isAdjacentToOwned(hex, in: state)
    }

    #if DEBUG
    func resetForTesting() {
        state = .empty
        persist()
    }
    #endif
}
