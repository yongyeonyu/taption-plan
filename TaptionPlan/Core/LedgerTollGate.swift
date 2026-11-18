import Foundation
import TaptionPlanCore

/// 고속도로 영업소(톨게이트) 하나. 목록은 중계 서버 `/ex/units`(한국도로공사 영업소 위치)에서 통째로 받아 기기에 둔다.
struct TollUnit: Codable, Equatable, Sendable {
    var code: String
    var name: String
    var route: String
    var lat: Double
    var lng: Double
}

/// 지난 톨게이트로 통행료 알아내기(TGT1118A01, 대표 결정 2026-11-18).
/// 이동의 정확한 위치를 영업소 목록과 기기 안에서 견준다. 위치는 서버로 보내지 않고, 요금은 영업소 코드만 보내 묻는다.
/// - 지남: 위치(또는 2분 안에 이어진 두 위치 사이의 선)가 영업소에서 `passMeters` 안으로 들어옴. 영업소마다 가장 가까웠던 때 하나.
/// - 두 곳 이상: 처음 = 입구, 끝 = 출구(폐쇄식). 한 곳: 본선 영업소(개방식), 출발·도착을 같은 코드로 묻는다.
/// - 확실함: 쓰는 영업소(입구·출구 또는 본선 하나)가 모두 `preciseMeters` 안 + 위치 오차 `preciseAccuracy` 이하,
///   사이에 또 가까이 지난 영업소가 없고, 요금이 한 값(0원 초과)으로 왔고, 입구와 출구 시각의 할인이 같다.
///   하나라도 아니면 「확인 필요」에 올린다. 영업소를 못 찾으면 같은 길 통행료(`LedgerTollRepeat`)에 맡긴다.
/// - 요금 0건(개방식 일부 구간·민자 노선): 요금을 모르는 것이라 같은 길의 배운 금액으로 넣되 늘 「확인 필요」에 올린다.
///   서버에 묻지 못했으면(키 없음·네트워크) 같은 길 방식 그대로 두고, 다음에 다시 묻는다.
/// - 할인: 1종 정상요금에 `LedgerTollDiscount`를 한 번만 적용한다(경차는 6종 금액을 쓰지 않고 1종에 경차 50%).
///   포털의 시간대 할인 칸(odn1·odn2)은 쓰지 않는다. 출퇴근 할인은 영업소 사이 20km 이상이면 뺀다.
enum LedgerTollGate {
    /// 이만큼 가까우면 지난 것으로 본다.
    static let passMeters = 150.0
    /// 확실하다고 보는 거리와 위치 오차.
    static let preciseMeters = 80.0
    static let preciseAccuracy = 50.0
    /// 두 위치 사이를 이어 보는 한도(고속도로에서 띄엄띄엄 잡힌 위치).
    static let joinSeconds: TimeInterval = 120
    static let joinMeters = 3_000.0
    /// 출퇴근 할인은 입구·출구 영업소 사이 20km 미만에만 준다(한국도로공사).
    static let commuteLimitKm = 20.0
    static let notes = ["지난 톨게이트로 자동 추가", "Added from the toll plazas passed"]

    struct Fix: Equatable {
        var at: Date
        var latitude: Double
        var longitude: Double
        var accuracy: Double
    }

    struct Pass: Equatable {
        var code: String
        var name: String
        var at: Date
        var meters: Double
        var accuracy: Double

        var isPrecise: Bool { meters <= LedgerTollGate.preciseMeters && accuracy <= LedgerTollGate.preciseAccuracy }
    }

    struct Trip: Equatable {
        enum Kind: Equatable {
            /// 입구와 출구 영업소가 따로 있는 길.
            case closed(entry: Pass, exit: Pass)
            /// 본선 영업소 하나만 지나는 길.
            case single(Pass)
        }
        var kind: Kind
        /// 입구와 출구 사이에 또 가까이 지난 영업소가 있다(본선 영업소를 더 지났을 수 있다).
        var middlePrecise: Bool

        var codes: (from: String, to: String) {
            switch kind {
            case let .closed(entry, exit): (entry.code, exit.code)
            case let .single(pass): (pass.code, pass.code)
            }
        }

        var isPrecise: Bool {
            switch kind {
            case let .closed(entry, exit): entry.isPrecise && exit.isPrecise && !middlePrecise
            case let .single(pass): pass.isPrecise
            }
        }
    }

    enum Fare: Equatable {
        /// 정상요금이 한 값으로 왔다.
        case known(normal: Double, distanceKm: Double?)
        /// 운영 기관·경로마다 값이 달라 하나로 정하지 못했다. 가장 큰 값을 쓰고 확인을 받는다.
        case ambiguous(normal: Double, distanceKm: Double?)
        /// 그 영업소 사이 요금이 없다.
        case missing
    }

    struct Addition {
        var entry: LedgerEntry
        var applied: LedgerTollDiscount.Applied
        var certain: Bool
    }

    // MARK: 지남 판정

    /// 영업소마다 가장 가까웠던 때. 시각순.
    static func passes(units: [TollUnit], fixes: [Fix]) -> [Pass] {
        let fixes = fixes.sorted { $0.at < $1.at }
        guard let first = fixes.first else { return [] }
        // 이동이 지난 범위(조금 넓혀)의 영업소만 본다.
        let margin = 0.01
        let lats = fixes.map(\.latitude), lngs = fixes.map(\.longitude)
        let south = (lats.min() ?? first.latitude) - margin, north = (lats.max() ?? first.latitude) + margin
        let west = (lngs.min() ?? first.longitude) - margin, east = (lngs.max() ?? first.longitude) + margin
        let nearby = units.filter { $0.lat >= south && $0.lat <= north && $0.lng >= west && $0.lng <= east }
        return nearby.compactMap { unit in closest(unit, fixes: fixes) }.sorted { $0.at < $1.at }
    }

    private static func closest(_ unit: TollUnit, fixes: [Fix]) -> Pass? {
        var best: Pass?
        func consider(_ meters: Double, at: Date, accuracy: Double) {
            guard meters <= passMeters, best.map({ meters < $0.meters }) ?? true else { return }
            best = Pass(code: unit.code, name: unit.name, at: at, meters: meters, accuracy: accuracy)
        }
        for (index, fix) in fixes.enumerated() {
            let here = local(fix, around: unit)
            consider(hypot(here.x, here.y), at: fix.at, accuracy: fix.accuracy)
            guard index > 0 else { continue }
            let previous = fixes[index - 1]
            let before = local(previous, around: unit)
            let dx = here.x - before.x, dy = here.y - before.y
            let length = hypot(dx, dy)
            guard length > 0, length <= joinMeters, fix.at.timeIntervalSince(previous.at) <= joinSeconds else { continue }
            let t = max(0, min(1, -(before.x * dx + before.y * dy) / (length * length)))
            let meters = hypot(before.x + dx * t, before.y + dy * t)
            let at = previous.at.addingTimeInterval(fix.at.timeIntervalSince(previous.at) * t)
            consider(meters, at: at, accuracy: max(fix.accuracy, previous.accuracy))
        }
        return best
    }

    /// 영업소를 원점으로 한 평면 좌표(m). 수 km 안에서만 쓰므로 평면으로 본다.
    private static func local(_ fix: Fix, around unit: TollUnit) -> (x: Double, y: Double) {
        let x = (fix.longitude - unit.lng) * 111_320 * cos(unit.lat * .pi / 180)
        let y = (fix.latitude - unit.lat) * 110_540
        return (x, y)
    }

    /// 지난 영업소로 길 모양을 정한다. 없으면 nil.
    static func trip(_ passes: [Pass]) -> Trip? {
        let passes = passes.sorted { $0.at < $1.at }
        guard let entry = passes.first, let exit = passes.last else { return nil }
        guard passes.count >= 2 else { return Trip(kind: .single(entry), middlePrecise: false) }
        return Trip(kind: .closed(entry: entry, exit: exit), middlePrecise: passes.dropFirst().dropLast().contains(where: \.isPrecise))
    }

    // MARK: 요금

    /// 서버 `/ex/fare` 응답. 읽지 못하면 nil(다음에 다시 묻는다).
    static func fare(_ data: Data, from: String, to: String) -> Fare? {
        struct Reply: Decodable {
            struct Row: Decodable { var from: String; var to: String; var normal: Double; var distanceKm: Double? }
            var fares: [Row]
        }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else { return nil }
        let rows = reply.fares.filter { $0.from == from && $0.to == to && $0.normal > 0 }
        guard let top = rows.max(by: { $0.normal < $1.normal }) else { return .missing }
        return Set(rows.map(\.normal)).count == 1
            ? .known(normal: top.normal, distanceKm: top.distanceKm)
            : .ambiguous(normal: top.normal, distanceKm: top.distanceKm)
    }

    /// 그 시각의 할인. 출퇴근 할인은 영업소 사이가 20km 이상이면 주지 않는다(차종 할인은 그대로).
    static func applied(
        at date: Date, distanceKm: Double?, vehicle: LedgerTollDiscount.Vehicle, isOffDay: Bool, calendar: Calendar
    ) -> LedgerTollDiscount.Applied {
        let applied = LedgerTollDiscount.applied(at: date, vehicle: vehicle, isOffDay: isOffDay, calendar: calendar)
        guard [.commuteHalf, .commuteFifth].contains(applied.reason), let distanceKm, distanceKm >= commuteLimitKm else { return applied }
        let own = LedgerTollDiscount.vehicleRate(vehicle, year: calendar.component(.year, from: date))
        return own > 0 ? .init(rate: own, reason: vehicle == .compact ? .compact : .electric) : .init(rate: 0, reason: .none)
    }

    // MARK: 넣을 것

    /// 넣을 만한 이동: 자리 잡은(도착 10분 뒤) 자동차 이동 중 아직 안 본 것, 그 무렵 통행료가 없는 것, 영업소를 지난 것.
    static func candidates(
        drives: [LedgerTollRepeat.Drive], existing: [LedgerEntry], handled: Set<String>, now: Date
    ) -> [(drive: LedgerTollRepeat.Drive, trip: Trip)] {
        let tolls = existing.filter(LedgerTollRepeat.isToll).map(\.occurredAt)
        return LedgerTollRepeat.merged(drives).compactMap { drive in
            guard !handled.contains(drive.key), drive.end <= now.addingTimeInterval(-LedgerTollRepeat.settle),
                  !tolls.contains(where: { LedgerTollRepeat.covers(drive, $0) }),
                  let trip = trip(drive.passes) else { return nil }
            return (drive, trip)
        }
    }

    /// 넣을 통행료. 요금이 없으면 nil(같은 길 통행료에 맡긴다).
    @MainActor
    static func addition(
        trip: Trip, fare: Fare, vehicle: LedgerTollDiscount.Vehicle, isOffDay: (Date) -> Bool,
        calendar: Calendar, language: MapHomeLanguage
    ) -> Addition? {
        let normal: Double, distanceKm: Double?, fareKnown: Bool
        switch fare {
        case let .known(value, km): (normal, distanceKm, fareKnown) = (value, km, true)
        case let .ambiguous(value, km): (normal, distanceKm, fareKnown) = (value, km, false)
        case .missing: return nil
        }
        func rate(_ date: Date) -> LedgerTollDiscount.Applied {
            applied(at: date, distanceKm: distanceKm, vehicle: vehicle, isOffDay: isOffDay(date), calendar: calendar)
        }
        let paidAt: Date, sameRate: Bool, title: String, route: String
        switch trip.kind {
        case let .closed(entry, exit):
            paidAt = exit.at
            sameRate = rate(entry.at) == rate(exit.at)
            let from = plaza(entry.name, language: language), to = plaza(exit.name, language: language)
            route = "\(from) → \(to)"
            title = language.text("\(from) → \(to) 통행료", "Toll: \(from) → \(to)")
        case let .single(pass):
            paidAt = pass.at
            sameRate = true
            route = plaza(pass.name, language: language)
            title = language.text("\(route) 통행료", "Toll: \(route)")
        }
        let discount = rate(paidAt)
        var entry = LedgerEntry(occurredAt: paidAt, amount: LedgerTollDiscount.amount(base: normal, rate: discount.rate), title: title)
        entry.category = .transport
        let money = LedgerMoney.text(normal, language: language)
        entry.note = ([language.text("지난 톨게이트로 자동 추가", "Added from the toll plazas passed"), route,
                       language.text("정상요금 \(money)", "Normal fare \(money)")]
            + [LedgerTollDiscount.label(discount, language: language)].compactMap { $0 }).joined(separator: " · ")
        return Addition(entry: entry, applied: discount, certain: trip.isPrecise && fareKnown && sameRate)
    }

    static func plaza(_ name: String, language: MapHomeLanguage) -> String {
        name.hasSuffix("영업소") ? name : language.text("\(name) 영업소", "\(name) toll plaza")
    }
}

/// 기기에 둔 영업소 목록. 7일마다 새로 받고, 받지 못하면 있던 것을 쓰고 1시간 뒤 다시 본다.
@MainActor
enum TollUnitStore {
    nonisolated static let maximumUnits = 3_000
    nonisolated static let maximumBytes = 1_000_000
    static let refreshAfter: TimeInterval = 7 * 86_400
    static let retryAfter: TimeInterval = 60 * 60
    private static var lastAttempt = Date.distantPast
    private static var memory: Saved?

    struct Saved: Codable {
        var savedAt: Date
        var units: [TollUnit]
    }

    static var file: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("toll-units.json")
    }

    static func units(now: Date = .now, env: AssistantRegistration.Environment = .live) async -> [TollUnit] {
        let saved = memory ?? read()
        memory = saved
        if let saved, now.timeIntervalSince(saved.savedAt) < refreshAfter { return saved.units }
        guard now.timeIntervalSince(lastAttempt) >= retryAfter else { return saved?.units ?? [] }
        lastAttempt = now
        guard let fresh = await fetch(env: env) else { return saved?.units ?? [] }
        let next = Saved(savedAt: now, units: fresh)
        memory = next
        if let data = try? JSONEncoder().encode(next), data.count <= maximumBytes { try? data.write(to: file, options: .atomic) }
        return fresh
    }

    /// 서버 응답을 읽는다. 비었거나 모양이 다르면 nil.
    nonisolated static func decode(_ data: Data) -> [TollUnit]? {
        struct Reply: Decodable { var units: [TollUnit] }
        guard data.count <= maximumBytes, let units = try? JSONDecoder().decode(Reply.self, from: data).units else { return nil }
        let valid = units.filter { !$0.code.isEmpty && abs($0.lat) <= 90 && abs($0.lng) <= 180 }
        return valid.isEmpty ? nil : Array(valid.prefix(maximumUnits))
    }

    private static func read() -> Saved? {
        guard let data = try? Data(contentsOf: file), data.count <= maximumBytes else { return nil }
        return try? JSONDecoder().decode(Saved.self, from: data)
    }

    private static func fetch(env: AssistantRegistration.Environment) async -> [TollUnit]? {
        guard let token = await AssistantRegistration.searchToken(),
              let reply = await TripRelay.send(TripRelay.relayRequest("/ex/units", method: "GET", token: token, host: env.host, client: env.client(), timeout: 20), session: env.session),
              reply.status == 200 else { return nil }
        return decode(reply.data)
    }
}

/// 영업소 사이 요금. 영업소 코드와 차종(1종)만 보낸다. 받은 값은 30일(없다는 답은 1일) 기기에 둔다.
@MainActor
enum LedgerTollFareStore {
    static let key = "ledgerTollGateFares"
    static let limit = 300

    struct Saved: Codable {
        var fare: Stored
        var savedAt: Date
    }

    enum Stored: Codable, Equatable {
        case known(Double, Double?), ambiguous(Double, Double?), missing

        var fare: LedgerTollGate.Fare {
            switch self {
            case let .known(normal, km): .known(normal: normal, distanceKm: km)
            case let .ambiguous(normal, km): .ambiguous(normal: normal, distanceKm: km)
            case .missing: .missing
            }
        }

        init(_ fare: LedgerTollGate.Fare) {
            switch fare {
            case let .known(normal, km): self = .known(normal, km)
            case let .ambiguous(normal, km): self = .ambiguous(normal, km)
            case .missing: self = .missing
            }
        }
    }

    /// 묻지 못하면(키 없음·네트워크) nil.
    static func fare(from: String, to: String, now: Date = .now, defaults: UserDefaults = .standard,
                     env: AssistantRegistration.Environment = .live) async -> LedgerTollGate.Fare? {
        let name = "\(from)|\(to)|1"
        var saved = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([String: Saved].self, from: $0) } ?? [:]
        if let hit = saved[name], now.timeIntervalSince(hit.savedAt) < (hit.fare == .missing ? 86_400 : 30 * 86_400) { return hit.fare.fare }
        let query = [URLQueryItem(name: "from", value: from), URLQueryItem(name: "to", value: to), URLQueryItem(name: "car", value: "1")]
        guard let token = await AssistantRegistration.searchToken(),
              let reply = await TripRelay.send(TripRelay.relayRequest("/ex/fare", method: "GET", query: query, token: token, host: env.host, client: env.client()), session: env.session),
              reply.status == 200, let fare = LedgerTollGate.fare(reply.data, from: from, to: to) else { return nil }
        saved[name] = Saved(fare: Stored(fare), savedAt: now)
        if saved.count > limit {
            for old in saved.sorted(by: { $0.value.savedAt < $1.value.savedAt }).prefix(saved.count - limit) { saved[old.key] = nil }
        }
        if let data = try? JSONEncoder().encode(saved) { defaults.set(data, forKey: key) }
        return fare
    }
}

/// 같은 길 통행료보다 먼저 돈다. 넣었거나 「확인 필요」에 올린 이동의 열쇠(같은 길 쪽이 다시 넣지 않게)와
/// 영업소는 알지만 요금이 0건인 이동의 열쇠(같은 길 쪽이 「확인 필요」로 올리게)를 돌려준다.
@MainActor
enum LedgerTollGateRunner {
    static func run(
        drives: [LedgerTollRepeat.Drive], existing: [LedgerEntry], handled: Set<String>, now: Date,
        vehicle: LedgerTollDiscount.Vehicle, isOffDay: @escaping (Date) -> Bool, calendar: Calendar, language: MapHomeLanguage
    ) async -> (done: [String], unknownFare: Set<String>) {
        var done: [String] = []
        var unknownFare = Set<String>()
        for candidate in LedgerTollGate.candidates(drives: drives, existing: existing, handled: handled, now: now) {
            let codes = candidate.trip.codes
            guard let fare = await LedgerTollFareStore.fare(from: codes.from, to: codes.to, now: now) else { continue }
            if fare == .missing { unknownFare.insert(candidate.drive.key) }
            guard let addition = LedgerTollGate.addition(trip: candidate.trip, fare: fare, vehicle: vehicle, isOffDay: isOffDay,
                                                         calendar: calendar, language: language) else { continue }
            // 대표 결정: 확실하면 바로 넣고, 아니면 「확인 필요」에 올린다(지하철 요금과 같은 방식).
            if addition.certain { await LedgerBook.shared.save(addition.entry) } else { LedgerReviewStore.shared.add(addition.entry, reason: .toll, now: now) }
            done.append(candidate.drive.key)
            TaptionPlanDiagnosticsLogger.shared.record("ledger_toll_gate_added", fields: [
                "amount": String(Int(addition.entry.amount)), "certain": addition.certain ? "1" : "0",
            ])
        }
        return (done, unknownFare)
    }
}

/// 도로공사 자료로 통행료를 모를 때만 카카오 길찾기에 묻는다(KDR1118A01, 대표 결정 2026-11-18, `AGENTS.md` 좌표 예외 TGT1118A01).
/// 보내는 것은 그 이동의 출발·도착과 경유지 최대 5개 좌표뿐이고, 서버는 저장하지 않는다.
/// 실제 지난 길이 아니라 그 점들로 다시 그린 길의 예상이라 늘 「확인 필요」로 올린다.
enum LedgerTollKakao {
    struct Point: Equatable, Sendable {
        var at: Date
        var latitude: Double
        var longitude: Double
    }

    struct Route: Equatable, Sendable {
        var found: Bool
        var toll: Double
        var roads: [String]
    }

    static let notes = ["카카오 길찾기로 자동 추가", "Added from Kakao directions"]
    static let maximumWaypoints = 5
    /// 이만큼 칸(약 1km)을 지난 이동만 묻는다. 동네 길은 묻지 않는다.
    static let minimumCells = 8
    static let askedKey = "ledgerTollKakaoAsked"

    /// 고르게 고른 점: 처음·끝과 그 사이 최대 5개.
    static func sampled(_ points: [Point]) -> [Point] {
        let sorted = points.sorted { $0.at < $1.at }
        guard sorted.count > maximumWaypoints + 2 else { return sorted }
        let last = sorted.count - 1
        let inner = (1...maximumWaypoints).map { sorted[Int((Double($0) * Double(last) / Double(maximumWaypoints + 1)).rounded())] }
        return [sorted[0]] + inner + [sorted[last]]
    }

    /// 서버에 보낼 본문. 점이 둘보다 적으면 묻지 않는다.
    static func body(_ points: [Point]) -> Data? {
        let picked = sampled(points)
        guard picked.count >= 2, let first = picked.first, let last = picked.last else { return nil }
        func value(_ point: Point) -> [String: Double] { ["lat": point.latitude, "lng": point.longitude] }
        let object: [String: Any] = ["origin": value(first), "destination": value(last), "waypoints": picked.dropFirst().dropLast().map(value)]
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static func decode(_ data: Data) -> Route? {
        struct Reply: Decodable { var found: Bool; var toll: Double?; var roads: [String]? }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else { return nil }
        return Route(found: reply.found, toll: max(0, reply.toll ?? 0), roads: reply.roads ?? [])
    }

    /// 물을 이동: 정착했고, 다른 방식(지난 톨게이트·같은 길)으로 처리하지 않았고, 그 무렵 통행료가 없고, 길게 달렸고, 아직 묻지 않은 것.
    static func candidates(
        drives: [LedgerTollRepeat.Drive], existing: [LedgerEntry], handled: Set<String>, asked: Set<String>, now: Date
    ) -> [LedgerTollRepeat.Drive] {
        let tolls = existing.filter(LedgerTollRepeat.isToll).map(\.occurredAt)
        return LedgerTollRepeat.merged(drives).filter { drive in
            !handled.contains(drive.key) && !asked.contains(drive.key)
                && drive.end <= now.addingTimeInterval(-LedgerTollRepeat.settle)
                && drive.cells.count >= minimumCells && drive.points.count >= 2
                && !tolls.contains { LedgerTollRepeat.covers(drive, $0) }
        }
    }

    /// 「확인 필요」에 올릴 기록. 통행료가 없으면 nil.
    static func entry(drive: LedgerTollRepeat.Drive, route: Route, language: MapHomeLanguage) -> LedgerEntry? {
        guard route.found, route.toll > 0 else { return nil }
        let highways = route.roads.filter { $0.contains("고속도로") || $0.localizedCaseInsensitiveContains("expressway") }
        let named = highways.isEmpty ? language.text("고속도로", "Expressway") : highways.prefix(2).joined(separator: "·")
        var entry = LedgerEntry(occurredAt: drive.end, amount: route.toll, title: language.text("\(named) 통행료", "Toll: \(named)"))
        entry.category = .transport
        entry.note = [language.text("카카오 길찾기로 자동 추가", "Added from Kakao directions"), "\(drive.from) → \(drive.to)",
                      language.text("카카오 예상 통행료", "Kakao estimated toll")].joined(separator: " · ")
        return entry
    }
}

/// 같은 길 통행료 다음에 돈다. 「확인 필요」에 올린 이동의 열쇠를 돌려준다.
@MainActor
enum LedgerTollKakaoRunner {
    /// 묻지 못하면(키 없음·한도·네트워크) 1시간 쉰다.
    private static var pausedUntil = Date.distantPast
    /// 한 번 돌 때 묻는 이동 수.
    static let perRun = 3

    static func run(
        drives: [LedgerTollRepeat.Drive], existing: [LedgerEntry], handled: Set<String>, now: Date,
        defaults: UserDefaults = .standard, language: MapHomeLanguage, env: AssistantRegistration.Environment = .live
    ) async -> [String] {
        guard now >= pausedUntil else { return [] }
        var asked = defaults.stringArray(forKey: LedgerTollKakao.askedKey) ?? []
        var done: [String] = []
        let candidates = LedgerTollKakao.candidates(drives: drives, existing: existing, handled: handled, asked: Set(asked), now: now)
        for drive in candidates.prefix(perRun) {
            guard let body = LedgerTollKakao.body(drive.points) else { continue }
            guard let token = await AssistantRegistration.searchToken(),
                  let reply = await TripRelay.send(TripRelay.relayRequest("/kakao/directions", method: "POST", body: body, token: token,
                                                                          host: env.host, client: env.client()), session: env.session),
                  reply.status == 200, let route = LedgerTollKakao.decode(reply.data) else {
                pausedUntil = now.addingTimeInterval(60 * 60)
                break
            }
            // 통행료가 없던 이동도 다시 묻지 않는다.
            asked.append(drive.key)
            guard let entry = LedgerTollKakao.entry(drive: drive, route: route, language: language) else { continue }
            LedgerReviewStore.shared.add(entry, reason: .toll, now: now)
            done.append(drive.key)
            TaptionPlanDiagnosticsLogger.shared.record("ledger_toll_kakao_review", fields: ["amount": String(Int(entry.amount))])
        }
        defaults.set(Array(asked.suffix(200)), forKey: LedgerTollKakao.askedKey)
        return done
    }
}
