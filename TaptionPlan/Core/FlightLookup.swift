import Foundation
import TaptionPlanEngine

/// 서버 `/flights/*`가 돌려주는 항공편 한 줄(FLT1119A01). 앱은 공항 코드·날짜·방향·편명만 보내고, 개인 정보는 어떤 경로로도 보내지 않는다.
struct FlightListing: Decodable, Equatable, Identifiable, Sendable {
    var flight: String
    var airline: String
    var origin: String
    var destination: String
    /// 그 공항(조회한 공항)의 현지 시각 `HH:mm`.
    var time: String
    /// 국내선 두 시각(FLT1120A01, 서버가 줄 때만). 출발·도착 공항의 현지 `HH:mm`과 비행 분.
    var departureTime: String?
    var arrivalTime: String?
    var durationMinutes: Int?
    var dayOffset: Int
    var terminal: String?
    var gate: String?
    var codeshare: Bool
    var master: String?
    var season: String?
    var status: FlightLiveStatus?

    var id: String { "\(flight)|\(time)|\(origin)|\(destination)" }
}

/// 당일 운항현황(인천만 연결). 없으면 「정기 스케줄 기준」이다.
struct FlightLiveStatus: Decodable, Equatable, Sendable {
    var state: String
    var scheduled: String?
    var expected: String?
    var delayMinutes: Int
    var terminal: String?
    var gate: String?
    var baggage: String?

    var isProblem: Bool { state == "delayed" || state == "cancelled" }
}

/// 한 번 조회한 결과.
struct FlightListResult: Equatable, Sendable {
    enum Source: String, Sendable { case season, status }
    var flights: [FlightListing]
    var source: Source
    var updatedAt: Date?
    /// 당일 운항현황을 줄 수 있는 공항인가(정기 스케줄은 항상 true).
    var isAvailable: Bool
}

enum FlightLookup {
    enum Kind: String, Sendable { case schedule, status }
    enum Direction: String, Sendable { case dep, arr }
    /// 조회하지 못한 이유. 앱은 어느 것이든 오류 화면 없이 「직접 입력 + 편명으로 검색」만 보여 준다.
    enum Failure: Equatable, Sendable { case noServer, routeMissing, keyMissing, limited, outOfRange, failed }
    enum Outcome: Equatable, Sendable {
        case found(FlightListResult)
        case unavailable(Failure)
    }

    nonisolated static let maximumBytes = 600_000
    /// 편명 검색 링크(예약·가격 아님). 검색 엔진 주소를 상수로 둔다.
    nonisolated static let searchBase = "https://www.google.com/search?q="

    /// 서버로 보내는 쿼리. 공항·날짜·방향·편명만이다(예약번호·이름은 이 함수에 들어오지 않는다).
    nonisolated static func query(airport: String, day: String, direction: Direction, flight: String? = nil) -> [URLQueryItem] {
        var items = [
            URLQueryItem(name: "airport", value: airport.uppercased()),
            URLQueryItem(name: "date", value: day),
            URLQueryItem(name: "direction", value: direction.rawValue),
        ]
        if let flight = flight?.replacingOccurrences(of: " ", with: "").uppercased(), !flight.isEmpty { items.append(URLQueryItem(name: "flight", value: flight)) }
        return items
    }

    /// 서버 응답을 읽는다. 상태 코드로 실패 이유를 가르고, 모양이 다르면 `failed`.
    nonisolated static func decode(_ data: Data, status: Int, now: Date = .now) -> Outcome {
        switch status {
        case 200: break
        case 400, 422: return .unavailable(.outOfRange)
        case 404: return .unavailable(.routeMissing)
        case 429: return .unavailable(.limited)
        case 503: return .unavailable(.keyMissing)
        default: return .unavailable(.failed)
        }
        struct Reply: Decodable {
            var source: String
            var updatedAt: String?
            var available: Bool?
            var flights: [FlightListing]
        }
        guard data.count <= maximumBytes, let reply = try? JSONDecoder().decode(Reply.self, from: data) else { return .unavailable(.failed) }
        let valid = reply.flights.filter { clockMinute($0.time) != nil && ($0.departureTime.map { clockMinute($0) != nil } ?? true) && ($0.arrivalTime.map { clockMinute($0) != nil } ?? true) && $0.flight.count >= 3 && $0.origin.count == 3 && $0.destination.count == 3 }
        return .found(FlightListResult(
            flights: valid, source: reply.source == "status" ? .status : .season,
            updatedAt: reply.updatedAt.flatMap(parseISO), isAvailable: reply.available ?? true
        ))
    }

    nonisolated static func parseISO(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    /// `HH:mm` → 그날 0시부터의 분. 모양이 다르면 nil.
    nonisolated static func clockMinute(_ text: String) -> Int? {
        let parts = text.split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]), (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return hour * 60 + minute
    }

    /// 정기 스케줄 줄에 당일 운항현황을 붙인다(같은 편명·같은 예정 시각). 스케줄이 비었으면 운항현황 줄을 그대로 쓴다.
    nonisolated static func merged(schedule: FlightListResult?, status: FlightListResult?) -> FlightListResult? {
        guard let schedule else { return status }
        guard let status, status.isAvailable, !status.flights.isEmpty else { return schedule }
        let live = Dictionary(status.flights.map { ("\($0.flight)|\($0.time)", $0) }, uniquingKeysWith: { first, _ in first })
        let flights = schedule.flights.map { row -> FlightListing in
            guard let match = live["\(row.flight)|\(row.time)"], let state = match.status else { return row }
            var joined = row
            joined.status = state
            joined.terminal = state.terminal ?? row.terminal
            joined.gate = state.gate ?? row.gate
            return joined
        }
        let attached = flights.contains { $0.status != nil }
        return FlightListResult(flights: flights, source: attached ? .status : .season, updatedAt: status.updatedAt ?? schedule.updatedAt, isAvailable: true)
    }

    /// 편명으로 검색하는 링크.
    nonisolated static func searchURL(for flight: String) -> URL? {
        let compact = flight.replacingOccurrences(of: " ", with: "").uppercased()
        guard !compact.isEmpty, let encoded = compact.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
        return URL(string: searchBase + encoded + "%20flight")
    }

    // MARK: 네트워크

    /// 서버에 묻는다. 서버 주소·검색 키가 없거나 막히면 `unavailable`이고 앱은 직접 입력으로 넘어간다.
    @MainActor
    static func fetch(
        _ kind: Kind, airport: String, day: String, direction: Direction, flight: String? = nil,
        env: AssistantRegistration.Environment = .live, now: Date = .now
    ) async -> Outcome {
        guard env.host != nil else { return .unavailable(.noServer) }
        guard let token = await AssistantRegistration.searchToken(),
              let request = TripRelay.relayRequest("/flights/\(kind.rawValue)", method: "GET", query: query(airport: airport, day: day, direction: direction, flight: flight),
                                                   token: token, host: env.host, client: env.client(), timeout: 20),
              let reply = await TripRelay.send(request, session: env.session) else { return .unavailable(.failed) }
        return decode(reply.data, status: reply.status, now: now)
    }
}
