import Observation

/// 홈 화면을 통째로 덮는 화면(LGS1115A01). 지금은 가계부만 잇는다.
enum MapHomeCover: Hashable, Sendable {
    case ledger
}

/// 덮개 묶음과 「홈이 살아 있는가」 판정. 순수 값이라 따로 시험한다.
struct MapHomeCoverSet: Equatable, Sendable {
    private(set) var covers: Set<MapHomeCover> = []

    var isCovered: Bool { !covers.isEmpty }

    /// 덮였는지가 바뀌었으면 true.
    mutating func set(_ cover: MapHomeCover, covering: Bool) -> Bool {
        let wasCovered = isCovered
        if covering { covers.insert(cover) } else { covers.remove(cover) }
        return wasCovered != isCovered
    }

    static func isHomeLive(isSceneActive: Bool, isCovered: Bool) -> Bool {
        isSceneActive && !isCovered
    }
}

/// 홈이 덮여 있는 동안 홈의 그리기·화면용 갱신을 멈추는 문(LGS1115A01).
/// 센서 원본 저장·자동 기록·도착 카드·Live Activity는 이 문과 무관하게 계속된다.
@MainActor
@Observable
final class MapHomeLiveGate {
    static let shared = MapHomeLiveGate()

    /// 덮였는지가 실제로 바뀔 때만 관찰자를 깨운다.
    private(set) var isCovered = false
    @ObservationIgnored private var covers = MapHomeCoverSet()

    func set(_ cover: MapHomeCover, covering: Bool) {
        guard covers.set(cover, covering: covering) else { return }
        isCovered = covers.isCovered
    }
}

/// 살아 있을 때는 관찰 값을 그대로 읽어 붙들어 두고, 덮였을 때는 붙들어 둔 값만 돌려준다.
/// 덮인 동안 `live`를 부르지 않으므로 Observation이 읽는 쪽을 깨우지 않는다.
struct MapHomeHeldValue<Value> {
    private(set) var held: Value

    init(_ initial: Value) { held = initial }

    mutating func read(isCovered: Bool, live: () -> Value) -> Value {
        if !isCovered { held = live() }
        return held
    }
}
