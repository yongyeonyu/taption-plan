import Foundation

// 여행 중 동행 위치(LOC1116S01, 규약 21절). 서버는 암호문만 본다. 평문은 기기에서만 만들고 푼다.

/// 위치 메시지의 상태. 좌표는 `ok`·`help`에만 있다.
public enum ShareLocationState: String, Codable, Sendable {
    /// 공유 중.
    case ok
    /// 잠깐 숨김(좌표 없음).
    case hide
    /// 도와주세요(좌표 있음).
    case help
    /// 끔(좌표 없음).
    case off

    public var carriesCoordinate: Bool { self == .ok || self == .help }
}

/// 암호문 안의 평문. 위도·경도·정확도·측정 시각·상태만 담는다(경로·속도·활동·건강·배터리는 보내지 않는다).
public struct ShareLocationPayload: Codable, Sendable, Equatable {
    public var v = ShareContentVersion.current
    public var s: ShareLocationState
    public var lat: Double?
    public var lon: Double?
    /// 수평 정확도(미터, 올림).
    public var acc: Int?
    /// 측정 시각(보낸 기기 시계, 밀리초).
    public var at: Int
    /// 도움 요청에만, 40자까지.
    public var note: String?

    public init(state: ShareLocationState, latitude: Double? = nil, longitude: Double? = nil, accuracy: Int? = nil, at: Int, note: String? = nil) {
        s = state
        lat = latitude
        lon = longitude
        acc = accuracy
        self.at = at
        self.note = note.map { String($0.prefix(Self.noteLimit)) }
    }

    public static let noteLimit = 40

    /// 좌표가 있어야 하는 상태에 좌표가 없거나 범위 밖이면 거짓.
    public var isValid: Bool {
        guard s.carriesCoordinate else { return lat == nil && lon == nil }
        guard let lat, let lon else { return false }
        return (-90...90).contains(lat) && (-180...180).contains(lon) && (acc ?? 0) >= 0
    }
}

/// 서버가 주는 위치 한 건(방송 `loc`, `hello.locs`, `GET loc`). 끔·지움은 `off`.
public struct ShareWireLocation: Codable, Sendable, Equatable {
    public var by: Int?
    public var cipher: String?
    public var epoch: Int?
    /// 서버가 받은 시각.
    public var at: Int?
    public var help: Bool?
    public var off: Bool?
    /// 기간 창이 바뀌어 모두 지워짐.
    public var all: Bool?
}

/// 위치를 보낼 수 있는 기간(밀리초, 서버 시각). 주인이 정하고 서버가 지킨다.
public struct ShareLocWindow: Codable, Sendable, Equatable {
    public var from: Int
    public var until: Int

    public init(from: Int, until: Int) {
        self.from = from
        self.until = until
    }

    public func contains(_ now: Int) -> Bool { now >= from && now < until }
}

/// 받아서 푼 동행 위치. 메모리에만 둔다.
public struct ShareReceivedLocation: Sendable, Equatable, Identifiable {
    public var by: Int
    public var payload: ShareLocationPayload
    /// 서버가 받은 시각(서버 시계). 「몇 분 전」은 이것으로 잰다(기기 시계가 달라도 맞게).
    public var receivedAt: Int

    public var id: Int { by }
    public var isHelp: Bool { payload.s == .help }
}

/// 받은 위치가 얼마나 묵었는지. 화면의 농도·표지를 정한다.
public enum ShareLocationFreshness: Sendable, Equatable {
    case fresh, dim, old, lost

    public static let dimAfterMs = 5 * 60_000
    public static let oldAfterMs = 15 * 60_000
    public static let lostAfterMs = 30 * 60_000

    public init(ageMs: Int) {
        switch ageMs {
        case ..<Self.dimAfterMs: self = .fresh
        case ..<Self.oldAfterMs: self = .dim
        case ..<Self.lostAfterMs: self = .old
        default: self = .lost
        }
    }
}

/// 거리·걸리는 시간 계산. 길찾기 서비스에 좌표를 보내지 않는다.
public enum ShareLocationMath {
    public static let walkingMetersPerMinute = 4500.0 / 60

    /// 두 점 사이의 직선(대원) 거리, 미터.
    public static func distanceMeters(_ a: (lat: Double, lon: Double), _ b: (lat: Double, lon: Double)) -> Double {
        let radius = 6_371_000.0
        let p1 = a.lat * .pi / 180, p2 = b.lat * .pi / 180
        let dp = p2 - p1, dl = (b.lon - a.lon) * .pi / 180
        let h = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * radius * asin(min(1, sqrt(h)))
    }

    /// 걸어서 대략 몇 분(올림, 1분 미만은 1).
    public static func walkingMinutes(meters: Double) -> Int { max(1, Int((meters / walkingMetersPerMinute).rounded(.up))) }

    /// 「몇 분 전」의 분. 1분 미만은 0.
    public static func minutesAgo(nowMs: Int, receivedAtMs: Int) -> Int { max(0, (nowMs - receivedAtMs) / 60_000) }
}

/// 위치 평문 ↔ 암호문. 암호문은 방 키로 잠그고, 항목 id는 `loc-<참여자 번호>`, 종류는 `loc`이다.
public enum ShareLocationSealer {
    public static let kind = "loc"
    public static func itemID(member: Int) -> String { "loc-\(member)" }

    public static func seal(_ payload: ShareLocationPayload, keys: ShareKeys, roomID: String, member: Int, epoch: Int, nonce: Data? = nil) throws -> String {
        guard payload.isValid else { throw ShareError.crypto }
        let plain = ShareCipher.padded(try ShareJSON.data(payload))
        return try ShareCipher.seal(plain, key: keys.encKey, context: ShareItemContext(roomID: roomID, itemID: itemID(member: member), kind: kind, epoch: epoch), nonce: nonce)
    }

    /// 풀리지 않거나 모양·범위가 틀리면 nil(버린다).
    public static func open(_ cipher: String, keys: ShareKeys, roomID: String, member: Int, epoch: Int) -> ShareLocationPayload? {
        guard let plain = ShareCipher.open(cipher, key: keys.encKey, context: ShareItemContext(roomID: roomID, itemID: itemID(member: member), kind: kind, epoch: epoch)),
              let payload = try? ShareJSON.decode(ShareLocationPayload.self, from: plain), payload.isValid else { return nil }
        return payload
    }
}
