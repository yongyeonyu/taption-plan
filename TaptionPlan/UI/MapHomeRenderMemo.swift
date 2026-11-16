import CoreLocation
import Foundation
import SwiftUI

/// 하루 센서 기록 합치기 결과를 입력이 바뀔 때까지 들고 있는다(ARC1030A01). 본문 안에서 값을 읽기만 하므로 참조 타입이다.
@MainActor
final class MapHomeDayReadingsCache {
    struct Key: Equatable {
        var day: Date
        var sourceRevision: UInt64
        var storedCount: Int
        var liveCount: Int
        var liveLastID: UUID?
        var latestID: UUID?
    }

    private var key: Key?
    private var cached: [SensorReading] = []

    func value(for key: Key) -> [SensorReading]? {
        self.key == key ? cached : nil
    }

    func store(_ value: [SensorReading], for key: Key) {
        self.key = key
        cached = value
    }
}

/// 센서 기록 묶음이 바뀌었는지 가리는 값. 기록 수천 개를 비교하지 않고 개수·마지막 번호로 본다(ARC1030A01).
struct MapHomeReadingsSignature: Equatable, Sendable {
    var day: Date
    var sourceRevision: UInt64?
    var storedCount: Int
    var storedLastID: UUID?
    var liveCount: Int
    var liveLastID: UUID?
    var latestID: UUID?
}

/// 값 하나를 키가 바뀔 때까지 들고 있는다. 본문이 같은 값을 매번 다시 계산하지 않게 한다(ARC1030A01).
@MainActor
final class MapHomeMemo<Key: Equatable, Value> {
    private var key: Key?
    private var value: Value?

    func value(for key: Key, compute: () -> Value) -> Value {
        if self.key == key, let value { return value }
        let fresh = compute()
        self.key = key
        value = fresh
        return fresh
    }
}

/// 이전 값을 먼저 돌려주고 새 값은 뒤에서 계산한다(stale-while-revalidate, ARC1030A01).
///
/// 재생 중에는 분이 바뀔 때마다 지하철 구간 해석 같은 무거운 계산이 메인 스레드를 100ms씩 막았다.
/// `group`(날짜·원본 번호)이 같은 동안은 이전 값을 그대로 쓰고 `step`(분)에 맞는 새 값은 백그라운드에서 만든다.
/// `group`이 바뀌면(다른 날·새 기록) 옛 값이 틀리므로 그때만 그 자리에서 계산한다.
@MainActor
final class MapHomeStaleWhileRevalidate<Group: Equatable & Sendable, Step: Equatable & Sendable, Value: Sendable> {
    private var group: Group?
    private var step: Step?
    private var value: Value?
    private var pendingStep: Step?
    private var generation = 0
    /// 새 값이 도착했을 때 알린다(재생이 아닐 때 화면을 다시 그리게 한다).
    var onUpdate: () -> Void = {}
    /// 새 값이 만들어질 때마다(그 자리 계산·백그라운드 계산 모두) 그 값을 넘긴다. 로그처럼 메인에서 한 번만 할 일에 쓴다.
    var onFresh: ((Value) -> Void)?

    func value(group: Group, step: Step, compute: @escaping @Sendable () -> Value) -> Value {
        if self.group == group, self.step == step, let value { return value }
        guard self.group == group, let stale = value else {
            let fresh = compute()
            generation += 1
            self.group = group
            self.step = step
            value = fresh
            pendingStep = nil
            onFresh?(fresh)
            return fresh
        }
        if pendingStep != step {
            pendingStep = step
            generation += 1
            let current = generation
            Task.detached(priority: .userInitiated) { [weak self] in
                let result = compute()
                await MainActor.run {
                    guard let self, self.generation == current else { return }
                    self.group = group
                    self.step = step
                    self.value = result
                    self.pendingStep = nil
                    self.onFresh?(result)
                    self.onUpdate()
                }
            }
        }
        return stale
    }
}

/// 탑승 후보가 바뀌는 "묶음" 표지. 컷오프(분)는 빠져 있다 — 같은 묶음 안에서 분만 바뀌면 이전 값을 먼저 보여 준다(ARC1030A01).
struct MapHomeTransitBoardingGroup: Equatable, Sendable {
    var dayProjectionRevision: UInt64
    var settingsHash: Int
    var readingsRevision: UInt64
    var nearbyPlacesRevision: UInt64
    var day: Date
}

/// 화랑이 동작 캐시 표지. 시각은 초 단위로 본다(ARC1030A01).
struct MapHomeStickmanActionKey: Equatable {
    var second: Int
    var sourceRevision: UInt64?
    var sleepCount: Int
    var frequentPlaceCount: Int
    var legCount: Int
    var expectedCount: Int
    var latestID: UUID?
    var hasSelection: Bool
    var calendarEventCount = 0
}

struct MapHomeHomeWeatherKey: Equatable {
    var minute: Int
    var weatherCount: Int
    var lastObservedAt: Date?
}

/// 선택한 분과 재생 중 현재 분. `@State`가 아니라 관찰 저장소다(ARC1030A01).
///
/// `@State` 값은 바뀌면 그것을 가진 `MapHomeView` 본문 전체를 다시 평가한다. 재생 중 이 값이 0.25초마다 바뀌어
/// 그때마다 25~50ms 멈췄다(Release 측정: 알림을 끄면 120fps, 켜면 100fps·멈춤 164개). 관찰 저장소는 이 값을 **읽는**
/// 화면 조각(`MapHomeObservingView` 안)만 다시 그린다.
@MainActor
@Observable
final class MapHomePlaybackProgress {
    var selectedMinute: Int?
    var currentMinute: Double?
    /// 관찰되지 않는 같은 값. 재생 중 느리게 갱신하는 조각이 의존성 없이 읽는다.
    @ObservationIgnored var rawSelectedMinute: Int?
    @ObservationIgnored var rawCurrentMinute: Double?
    /// 재생 중 초당 한 번만 오르는 박자. 느린 조각만 이것을 읽는다(ARC1030A01).
    var coarseTick = 0
    @ObservationIgnored private var lastCoarseUptime: TimeInterval = 0

    func advanceCoarseTickIfNeeded(nowUptime: TimeInterval, minimumInterval: TimeInterval = 1) {
        guard nowUptime - lastCoarseUptime >= minimumInterval else { return }
        lastCoarseUptime = nowUptime
        coarseTick &+= 1
    }
}

/// 켜져 있는 동안 분 읽기는 관찰 저장소를 건드리지 않고 원본 값을 돌려준다.
enum MapHomeMinuteFreeze {
    @MainActor static var isFrozen = false
}

/// 재생 중에는 초당 한 번(`coarseTick`)과 `token`이 바뀔 때만 다시 평가하는 조각.
/// 정지 상태의 token은 매번 달라 예전처럼 부모를 따라 갱신된다.
struct MapHomeCoarseView<Content: View>: View, Equatable {
    let progress: MapHomePlaybackProgress
    /// 재생 중이면 진행 박자(`coarseTick`)로만 다시 그린다. 아니면 늘 다시 그린다(예전 `Int.random` 토큰 대신, PRF1101A01).
    let isFrozen: Bool
    let content: () -> Content

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.isFrozen && rhs.isFrozen }

    @MainActor var body: some View {
        let _ = progress.coarseTick
        let _ = { MapHomeMinuteFreeze.isFrozen = true }()
        let view = content()
        let _ = { MapHomeMinuteFreeze.isFrozen = false }()
        return view
    }
}

/// 안쪽 클로저가 읽는 관찰 값이 바뀔 때 이 조각만 다시 평가한다. 바깥 본문의 의존성에는 들어가지 않는다(ARC1030A01).
struct MapHomeObservingView<Content: View>: View {
    let content: () -> Content

    init(@ViewBuilder _ content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View { content() }
}
