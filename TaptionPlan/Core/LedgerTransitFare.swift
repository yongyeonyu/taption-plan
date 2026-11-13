import CoreLocation
import Foundation
import TaptionPlanEngine

/// 버스·지하철 요금 자동 넣기(TRF1113A01, 대표 지시 「버스 한번 탔는데 그것도 알고리즘으로 구현해」).
/// 하루의 버스·지하철 이동을 요금표(`FareCalculator`, 수도권 통합환승·거리 비례)로 계산해 성인 요금을 가계부에 넣는다.
/// 이미 그 시간대에 교통비가 있으면(카드 알림·직접 입력) 넣지 않는다. 광역버스처럼 요금이 다를 수 있으면 「확인 필요」에 둔다.
/// 요금표 밖 지역이나 위치를 모르는 이동은 넣지 않는다(예전처럼 AI 「교통비 확인」이 맡는다).
enum LedgerTransitFare {
    struct Ride: Equatable, Sendable {
        var mode: TravelMode
        var start: Date
        var end: Date
        var meters: Double
        /// 버스 노선 종류로 정한 요금표 수단(BRT1113A01). 모르면 nil(간선·지선).
        var fareMode: String? = nil
    }

    struct Addition: Equatable {
        var key: String
        var entry: LedgerEntry
        var suspicious: Bool
    }

    /// 이보다 짧은 탑승은 GPS 흔들림으로 본다(AI 교통비 확인과 같은 3분).
    static let minimumSeconds: TimeInterval = 3 * 60
    /// 이 시간 안에 교통비가 이미 있으면 같은 이동의 요금으로 본다(AI 교통비 확인과 같은 30분).
    static let settleDelay: TimeInterval = 30 * 60
    /// 이보다 긴 버스 한 번은 광역·좌석 버스일 수 있어 확인을 받는다.
    static let longBusKm = 30.0

    static func tableMode(_ mode: TravelMode) -> String? {
        switch mode {
        case .bus: "서울_간선지선"
        case .subway: "rail"
        default: nil
        }
    }

    static func rides(_ segments: [TravelSegment]) -> [Ride] {
        segments.compactMap { segment -> Ride? in
            guard tableMode(segment.mode) != nil, segment.span.end.timeIntervalSince(segment.span.start) >= minimumSeconds else { return nil }
            let routes = segment.mode == .bus ? BusRouteCheck.known(segment).flatMap { $0.isEmpty ? nil : $0 } : nil
            return Ride(mode: segment.mode, start: segment.span.start, end: segment.span.end, meters: max(0, segment.distanceMeters),
                        fareMode: routes.map(BusRouteCheck.fareMode))
        }
        .sorted { $0.start < $1.start }
    }

    /// 탑승 바로 앞(없으면 바로 뒤)에 머문 곳의 좌표로 요금표 지역을 정한다.
    static func region(near start: Date, stays: [PlaceStay]) -> String? {
        let located = stays.filter { $0.point != nil }
        let before = located.filter { $0.span.start <= start }.max { $0.span.start < $1.span.start }
        let after = located.filter { $0.span.start > start }.min { $0.span.start < $1.span.start }
        guard let point = (before ?? after)?.point else { return nil }
        return TravelFareEstimate.region(CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude))
    }

    static func key(_ start: Date) -> String { "fare|\(Int(start.timeIntervalSince1970))" }

    static func title(_ legs: [FareLeg], language: MapHomeLanguage) -> String {
        let modes = Set(legs.map(\.mode))
        if modes.isSubset(of: ["서울_간선지선", "서울_광역", "경기_직행좌석"]) { return language.text("버스 요금", "Bus fare") }
        if modes == ["rail"] { return language.text("지하철 요금", "Subway fare") }
        return language.text("대중교통 요금", "Transit fare")
    }

    /// 넣을 요금. 환승은 한 번에 묶어 한 건이다.
    static func additions(
        rides: [Ride], region: String, existing: [LedgerEntry], handled: Set<String>,
        calculator: FareCalculator, language: MapHomeLanguage
    ) -> [Addition] {
        let legs = rides.compactMap { ride in
            (ride.fareMode ?? tableMode(ride.mode)).map { FareLeg(mode: $0, distanceKm: ride.meters / 1_000, boardedAt: ride.start, alightedAt: ride.end) }
        }
        guard !legs.isEmpty, let trips = calculator.trips(region: region, legs: legs, age: .adult) else { return [] }
        return trips.compactMap { trip -> Addition? in
            guard let start = trip.legs.first?.boardedAt, let end = trip.legs.last?.alightedAt, trip.fare > 0 else { return nil }
            let key = key(start)
            guard !handled.contains(key) else { return nil }
            let paid = existing.contains {
                $0.kind == .expense && $0.category == .transport && $0.canceledAt == nil
                    && $0.occurredAt >= start.addingTimeInterval(-settleDelay) && $0.occurredAt <= end.addingTimeInterval(settleDelay)
            }
            guard !paid else { return nil }
            var entry = LedgerEntry(occurredAt: start, amount: Double(trip.fare), title: title(trip.legs, language: language))
            entry.category = .transport
            let km = (trip.distanceKm * 10).rounded() / 10
            entry.note = language.text("요금표로 자동 계산 · 성인 · \(km)km", "Calculated from the fare table · adult · \(km) km")
            let suspicious = trip.legs.contains { $0.mode == "서울_간선지선" && $0.distanceKm > longBusKm }
            return Addition(key: key, entry: entry, suspicious: suspicious)
        }
    }
}

/// 앱을 열 때·기록이 바뀐 뒤(5분에 한 번) 오늘과 어제의 버스·지하철 이동을 본다. 통행료 관찰자가 함께 부른다.
@MainActor
enum LedgerTransitFareRunner {
    static let handledKey = "ledgerTransitFareHandled"
    private static var lastRunAt = Date.distantPast
    private static var isRunning = false

    static func run(model: AppModel, defaults: UserDefaults = .standard, now: Date = .now, force: Bool = false) async {
        guard !isRunning, force || now.timeIntervalSince(lastRunAt) >= 5 * 60, let calculator = FareCalculator.bundled else { return }
        isRunning = true
        lastRunAt = now
        defer { isRunning = false }
        let calendar = Calendar.autoupdatingCurrent
        var groups: [(rides: [LedgerTransitFare.Ride], region: String)] = []
        for offset in 0..<2 {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: calendar.startOfDay(for: now)),
                  let input = await model.assistantActivityInput(for: day, now: now, calendar: calendar) else { continue }
            // 내린 뒤 30분이 지나야 본다: 아직 환승 중일 수 있다.
            let rides = LedgerTransitFare.rides(input.travel).filter { now.timeIntervalSince($0.end) >= LedgerTransitFare.settleDelay }
            guard let first = rides.first, let region = LedgerTransitFare.region(near: first.start, stays: input.stays) else { continue }
            groups.append((rides, region))
        }
        guard !groups.isEmpty else { return }
        await LedgerBook.shared.load()
        guard LedgerBook.shared.isLoaded else { return }
        var handled = defaults.stringArray(forKey: handledKey) ?? []
        let language = MapHomeLanguage.current
        var added = false
        for group in groups {
            let additions = LedgerTransitFare.additions(
                rides: group.rides, region: group.region, existing: LedgerBook.shared.entries, handled: Set(handled),
                calculator: calculator, language: language
            )
            for addition in additions {
                // 앱이 먼저 넣고, 요금이 다를 수 있으면 「확인 필요」에 올린다(대표 지시, 통행료와 같은 방식).
                if addition.suspicious { LedgerReviewStore.shared.add(addition.entry, reason: .fare, now: now) } else { await LedgerBook.shared.save(addition.entry) }
                handled.append(addition.key)
                added = true
                TaptionPlanDiagnosticsLogger.shared.record("ledger_transit_fare_added", fields: ["amount": String(Int(addition.entry.amount))])
            }
        }
        if added { defaults.set(Array(handled.suffix(200)), forKey: handledKey) }
    }
}
