import Foundation

/// 항공편 찾기 화면의 순수 계산(FLT1120A01): 국내선 출발·도착 조회 합집합, 도착 시각 출처, 정렬·직항 거르기.
/// 화면은 이 값만 그린다. 서버로 나가는 것은 공항·날짜·방향·편명뿐이다.
enum FlightSearch {
    enum Sort: String, CaseIterable, Sendable { case departure, arrival, duration }

    /// 화면의 한 줄. 시각은 모두 그 공항의 현지 분(0~1439)이다.
    struct Row: Equatable, Identifiable, Sendable {
        var listing: FlightListing
        /// `listing.time`을 출발로 읽는지 도착으로 읽는지.
        var direction: FlightLookup.Direction
        var departureMinute: Int?
        var arrivalMinute: Int?
        /// 도착이 출발보다 며칠 뒤인가(자정을 넘기면 1).
        var arrivalDayOffset: Int
        var durationMinutes: Int?
        /// 도착(또는 출발) 시각을 서버가 주지 않아 거리로 어림했는가. 숨기지 않고 「어림」으로 보인다.
        var isEstimated: Bool

        var id: String { "\(listing.flight)|\(listing.origin)|\(listing.destination)" }
    }

    struct Result: Equatable, Sendable {
        var rows: [Row]
        /// 공동운항·대표편명이 아닌 줄을 뺀 건수(국내선 목록 아래에 건수만 보인다).
        var excludedCodeshare: Int
    }

    static func isCodeshare(_ listing: FlightListing) -> Bool {
        listing.codeshare || (listing.master.map { !$0.isEmpty && $0 != listing.flight } ?? false)
    }

    /// 국내선: 출발 공항의 출발 조회와 도착 공항의 도착 조회를 편명 하나로 합친다.
    /// 도착 시각은 서버 `arrivalTime` → 짝 행의 `time` → 거리 어림 순이고, 출발 시각이 없는 편은 도착에서 거꾸로 어림한다.
    static func domestic(dep: [FlightListing], arr: [FlightListing], origin: String, destination: String) -> Result {
        let o = origin.uppercased(), d = destination.uppercased()
        var excluded = Set<String>()
        func keep(_ rows: [FlightListing]) -> [FlightListing] {
            rows.filter { row in
                guard row.origin == o, row.destination == d else { return false }
                if isCodeshare(row) { excluded.insert(row.flight); return false }
                return true
            }
        }
        let departures = Dictionary(keep(dep).map { ($0.flight, $0) }, uniquingKeysWith: { first, _ in first })
        let arrivals = Dictionary(keep(arr).map { ($0.flight, $0) }, uniquingKeysWith: { first, _ in first })
        let estimate = estimatedMinutes(o, d)
        var rows: [Row] = []
        for flight in Set(departures.keys).union(arrivals.keys) {
            let depRow = departures[flight], arrRow = arrivals[flight]
            let known: (dep: Int?, arr: Int?) = (
                depRow.flatMap { $0.departureTime.flatMap(FlightLookup.clockMinute) ?? FlightLookup.clockMinute($0.time) } ?? arrRow?.departureTime.flatMap(FlightLookup.clockMinute),
                depRow?.arrivalTime.flatMap(FlightLookup.clockMinute) ?? arrRow.flatMap { FlightLookup.clockMinute($0.time) }
            )
            var depMinute = known.dep, arrMinute = known.arr, estimated = false
            if depMinute == nil, let a = arrMinute { depMinute = ((a - estimate) % 1_440 + 1_440) % 1_440; estimated = true }
            if arrMinute == nil, let s = depMinute { arrMinute = (s + estimate) % 1_440; estimated = true }
            guard let s = depMinute, let a = arrMinute else { continue }
            let duration = estimated ? estimate : ((a - s) % 1_440 + 1_440) % 1_440
            let base = depRow ?? arrRow!
            rows.append(Row(listing: base, direction: depRow != nil ? .dep : .arr, departureMinute: s, arrivalMinute: a,
                            arrivalDayOffset: (s + duration) / 1_440, durationMinutes: duration, isEstimated: estimated))
        }
        return Result(rows: rows.sorted { ($0.departureMinute ?? 0, $0.listing.flight) < ($1.departureMinute ?? 0, $1.listing.flight) },
                      excludedCodeshare: excluded.count)
    }

    /// 국제선: 조회한 한쪽 시각만 주어진다. 서버가 반대쪽 시각·비행 분을 주면 같이 보인다.
    static func international(_ listings: [FlightListing], direction: FlightLookup.Direction) -> Result {
        let rows = listings.map { row -> Row in
            let own = FlightLookup.clockMinute(row.time)
            let dep = direction == .dep ? own : row.departureTime.flatMap(FlightLookup.clockMinute)
            let arr = direction == .arr ? own : row.arrivalTime.flatMap(FlightLookup.clockMinute)
            return Row(listing: row, direction: direction, departureMinute: dep, arrivalMinute: arr, arrivalDayOffset: 0,
                       durationMinutes: row.durationMinutes, isEstimated: false)
        }
        return Result(rows: rows, excludedCodeshare: 0)
    }

    static func estimatedMinutes(_ origin: String, _ destination: String) -> Int {
        FlightPlacement.estimatedMinutes(origin: origin, destination: destination) ?? 60
    }

    /// 정렬. 시각이 없는 줄은 뒤로 간다.
    static func sorted(_ rows: [Row], by sort: Sort) -> [Row] {
        func key(_ row: Row) -> Int {
            switch sort {
            case .departure: row.departureMinute ?? row.arrivalMinute ?? Int.max
            case .arrival: (row.arrivalMinute.map { $0 + row.arrivalDayOffset * 1_440 }) ?? row.departureMinute ?? Int.max
            case .duration: row.durationMinutes ?? Int.max
            }
        }
        return rows.sorted { (key($0), $0.listing.flight) < (key($1), $1.listing.flight) }
    }

    /// 직항만: 공동운항 줄을 거른다.
    static func filtered(_ rows: [Row], directOnly: Bool) -> [Row] {
        directOnly ? rows.filter { !isCodeshare($0.listing) } : rows
    }

    static func clockText(_ minute: Int?) -> String {
        guard let minute else { return "--:--" }
        return String(format: "%02d:%02d", minute / 60 % 24, minute % 60)
    }

    /// `1시간 10분` / `1h 10m` 꼴의 분 표시를 위한 값(시간, 분).
    static func hoursAndMinutes(_ total: Int) -> (hours: Int, minutes: Int) { (total / 60, total % 60) }

    /// 국내선 공항: 한국 공항에서 국내선이 없는 인천을 뺀다.
    static func domesticAirportCodes() -> [String] {
        FlightPlacement.koreanAirports.map(\.code).filter { $0 != "ICN" }
    }

    static func isKorean(_ code: String) -> Bool { FlightPlacement.koreanAirports.contains { $0.code == code.uppercased() } }

    /// 두 공항이 모두 국내선 공항(한국이고 인천이 아님)이면 국내선.
    static func isDomestic(_ from: String?, _ to: String?) -> Bool {
        guard let from, let to else { return false }
        let codes = Set(domesticAirportCodes())
        return codes.contains(from.uppercased()) && codes.contains(to.uppercased())
    }
}
