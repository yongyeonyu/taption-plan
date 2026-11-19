import Foundation
import Synchronization

/// 이벤트 활성 판정에만 쓰는 시계 상태(기기에 남는다).
public struct SeasonPackClockState: Codable, Sendable, Equatable {
    /// 마지막으로 받은 중계 서버 `Date`와 그때의 기기 시각.
    public var anchorServer: Date?
    public var anchorDevice: Date?
    /// 신뢰한 시각의 최고점. 서버가 확인한 값에서만 올라간다.
    public var highWater: Date?

    public init(anchorServer: Date? = nil, anchorDevice: Date? = nil, highWater: Date? = nil) {
        self.anchorServer = anchorServer; self.anchorDevice = anchorDevice; self.highWater = highWater
    }
}

public protocol SeasonPackClockStorage: Sendable {
    func load() -> SeasonPackClockState
    func save(_ state: SeasonPackClockState)
}

public struct SeasonPackDefaultsClockStorage: SeasonPackClockStorage {
    private let suiteName: String?
    private let key: String

    public init(suiteName: String? = nil, key: String = "seasonPack.clock") {
        self.suiteName = suiteName; self.key = key
    }

    private var defaults: UserDefaults { suiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard }

    public func load() -> SeasonPackClockState {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(SeasonPackClockState.self, from: $0) } ?? SeasonPackClockState()
    }

    public func save(_ state: SeasonPackClockState) {
        if let data = try? JSONEncoder().encode(state) { defaults.set(data, forKey: key) }
    }
}

/// 신뢰 시각 = 최근 중계 서버 `Date` + 그 뒤 흐른 단조 시간. 서버가 24시간 넘게 없으면 기기 시각을 쓰되 마지막 신뢰 시각 + 48시간 안일 때만.
/// 기기 시각이 신뢰 시각보다 12시간 넘게 앞서거나 10분 넘게 뒤로 가면 의심으로 보고 서버가 확인할 때까지 이벤트를 켜지 않는다(fail-closed).
public final class SeasonPackClock: Sendable {
    public enum Reading: Sendable, Equatable {
        /// 서버 `Date` 기준으로 확인된 시각.
        case verified(Date)
        /// 서버 없이 기기 시각을 받아들인 경우(48시간 안).
        case device(Date)
        case suspicious

        /// 이벤트 판정에 쓸 시각. 의심이면 nil.
        public var date: Date? {
            switch self {
            case .verified(let date), .device(let date): date
            case .suspicious: nil
            }
        }
    }

    public static let liveWindow: TimeInterval = 24 * 3600
    public static let deviceGrace: TimeInterval = 48 * 3600
    public static let aheadTolerance: TimeInterval = 12 * 3600
    public static let behindTolerance: TimeInterval = 10 * 60

    private struct Live {
        var state: SeasonPackClockState
        var anchorMonotonic: TimeInterval?
        var savedHighWater: Date?
    }

    private let storage: SeasonPackClockStorage
    private let deviceNow: @Sendable () -> Date
    private let monotonic: @Sendable () -> TimeInterval
    private let live: Mutex<Live>
#if DEBUG
    private let debugDate = Mutex<(@Sendable () -> Date?)?>(nil)
#endif

    public init(
        storage: SeasonPackClockStorage,
        deviceNow: @escaping @Sendable () -> Date = { Date() },
        monotonic: @escaping @Sendable () -> TimeInterval = SeasonPackClock.systemMonotonic
    ) {
        self.storage = storage
        self.deviceNow = deviceNow
        self.monotonic = monotonic
        let state = storage.load()
        self.live = Mutex(Live(state: state, anchorMonotonic: nil, savedHighWater: state.highWater))
    }

    /// 잠잘 때도 흐르는 단조 시계(재부팅하면 처음으로 돌아간다).
    @Sendable public static func systemMonotonic() -> TimeInterval {
        TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000
    }

    /// 중계 서버 응답의 `Date` 헤더를 받았을 때 부른다(공지·팩·계획 어느 것이든).
    public func recordServerDate(_ date: Date) {
        let now = deviceNow()
        let mono = monotonic()
        let snapshot = live.withLock { live -> SeasonPackClockState in
            live.state = SeasonPackClockState(anchorServer: date, anchorDevice: now, highWater: date)
            live.anchorMonotonic = mono
            live.savedHighWater = date
            return live.state
        }
        storage.save(snapshot)
    }

    public func reading() -> Reading {
#if DEBUG
        if let override = debugDate.withLock({ $0 })?() { return .verified(override) }
#endif
        let device = deviceNow()
        let mono = monotonic()
        let (result, toSave) = live.withLock { live -> (Reading, SeasonPackClockState?) in
            if let server = live.state.anchorServer, let anchorMono = live.anchorMonotonic, mono >= anchorMono,
               mono - anchorMono <= Self.liveWindow {
                let expected = server.addingTimeInterval(mono - anchorMono)
                let delta = device.timeIntervalSince(expected)
                if delta > Self.aheadTolerance || delta < -Self.behindTolerance { return (.suspicious, nil) }
                let value = max(expected, live.state.highWater ?? expected)
                var save: SeasonPackClockState?
                if live.state.highWater.map({ value.timeIntervalSince($0) > 60 }) ?? true {
                    live.state.highWater = value
                    live.savedHighWater = value
                    save = live.state
                }
                return (.verified(value), save)
            }
            if let high = live.state.highWater {
                if device > high.addingTimeInterval(Self.deviceGrace) || device < high.addingTimeInterval(-Self.behindTolerance) {
                    return (.suspicious, nil)
                }
            }
            return (.device(device), nil)
        }
        if let toSave { storage.save(toSave) }
        return result
    }

    /// 이벤트 판정에 쓸 시각. 의심이면 nil(이벤트를 켜지 않는다).
    public var eventDate: Date? { reading().date }

#if DEBUG
    /// DEBUG 빌드 전용: 기준 시각 훅. Release에는 이 코드가 컴파일되지 않는다.
    public func setDebugDate(_ provider: (@Sendable () -> Date?)?) { debugDate.withLock { $0 = provider } }

    /// `-seasonPackDate 2026-12-25T21:00` 실행 인자를 읽는다(기기 시간대 기준). 없으면 nil.
    public static func debugDateFromLaunchArguments(
        _ arguments: [String] = ProcessInfo.processInfo.arguments,
        calendar: Calendar = .current
    ) -> Date? {
        guard let index = arguments.firstIndex(of: "-seasonPackDate"), arguments.indices.contains(index + 1) else { return nil }
        return SeasonPackDateParsing.localDateTime(arguments[index + 1], calendar: calendar)
    }
#endif
}
