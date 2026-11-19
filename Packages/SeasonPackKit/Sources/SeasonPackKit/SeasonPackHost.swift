import Foundation

public struct SeasonPackAnchor: Sendable, Equatable {
    public static let home = SeasonPackAnchor(dx: 0, dy: 0)
    public var dx: Double
    public var dy: Double
    public init(dx: Double, dy: Double) { self.dx = dx; self.dy = dy }
}

public enum SeasonPackDemoState: Sendable, Equatable {
    case flightStarted(SeasonPackRef)
    case flightEnded(SeasonPackRef)
    case giftsBurst(SeasonPackRef)
}

/// 앱이 구현하는 것은 이것 하나뿐이다. 패키지는 앱 타입·엔진·코어를 모른다.
public protocol SeasonPackHost: AnyObject, Sendable {
    /// `ko`·`en` 등 앱 언어 코드.
    var languageCode: String { get }
    /// `white`·`calico`·`mackerel`.
    var characterID: String { get }
    /// 집 좌표는 기기 안 일몰 계산에만 쓰이고 어디로도 나가지 않는다.
    var homeCoordinate: (latitude: Double, longitude: Double)? { get }
    var buildNumber: Int? { get }
    func now() -> Date
    func sunEvents(on day: Date) -> (sunrise: Date?, sunset: Date?)
    /// 기존 공지 시트로 보여 준다. 보여 줬으면 true(없는 공지면 false — 나중에 다시 시도한다).
    @MainActor func presentAnnouncement(id: String) -> Bool
    @MainActor func reportDemoState(_ state: SeasonPackDemoState)
}
