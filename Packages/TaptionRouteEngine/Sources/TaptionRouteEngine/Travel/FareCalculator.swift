import Foundation

/// 한 번 탄 구간. 시각은 환승 묶음을 가르는 데만 쓴다.
public struct FareLeg: Hashable, Sendable {
    public let mode: String
    public let distanceKm: Double
    public let boardedAt: Date
    public let alightedAt: Date

    public init(mode: String, distanceKm: Double, boardedAt: Date, alightedAt: Date) {
        self.mode = mode
        self.distanceKm = distanceKm
        self.boardedAt = boardedAt
        self.alightedAt = alightedAt
    }
}

/// 요금을 한 번 내는 묶음(환승으로 이어진 구간들).
public struct FareTrip: Hashable, Sendable {
    public let legs: [FareLeg]
    public let fare: Int

    public var distanceKm: Double { legs.reduce(0) { $0 + $1.distanceKm } }
}

/// 요금표만으로 계산한다. 네트워크·AI를 쓰지 않는다.
public struct FareCalculator: Sendable {
    public let table: FareTable

    public init(table: FareTable) {
        self.table = table
    }

    public static let bundled: FareCalculator? = FareTable.bundled.map(FareCalculator.init)

    /// 생일이 없으면 일반 요금이다.
    public func ageBand(birthDate: Date?, on date: Date = .now) -> FareAgeBand {
        guard let birthDate, let bands = table.ageBands,
              let age = calendar.dateComponents([.year], from: birthDate, to: date).year else { return .adult }
        if age >= bands.adultMinAge { return .adult }
        return age >= bands.teenMinAge ? .teen : .child
    }

    /// 한 수단만 탔을 때의 요금. 지역·수단·나이 요금이 표에 없으면 nil.
    public func fare(region: String, mode: String, distanceKm: Double = 0, age: FareAgeBand = .adult) -> Int? {
        guard let mode = table.regions[region]?.modes[mode], let amount = mode.fares[age.rawValue],
              let meters = Self.meters(distanceKm) else { return nil }
        let steps = (mode.bands ?? []).reduce(0) { $0 + Self.steps(meters: meters, band: $1) }
        return amount.base + (amount.extra ?? 0) * steps
    }

    /// 구간들을 환승 묶음으로 나눠 묶음마다 요금을 낸다.
    /// 환승(통합거리비례): 하차 뒤 환승 시간 안에 타면 한 묶음. 탄 수단 중 가장 높은 기본요금을 한 번 내고,
    /// 합친 거리가 기본거리(묶음 안 가장 큰 값)를 넘으면 단위 거리마다 그 수단의 추가요금을 더한다.
    public func trips(region: String, legs: [FareLeg], age: FareAgeBand = .adult) -> [FareTrip]? {
        guard let regionTable = table.regions[region] else { return nil }
        var groups: [[FareLeg]] = []
        for leg in legs.sorted(by: { $0.boardedAt < $1.boardedAt }) {
            if let last = groups.last, let previous = last.last,
               continues(previous, leg, boardings: last.count, in: regionTable) {
                groups[groups.count - 1].append(leg)
            } else {
                groups.append([leg])
            }
        }
        var trips: [FareTrip] = []
        for group in groups {
            guard let fare = fare(of: group, region: region, in: regionTable, age: age) else { return nil }
            trips.append(FareTrip(legs: group, fare: fare))
        }
        return trips
    }

    public func totalFare(region: String, legs: [FareLeg], age: FareAgeBand = .adult) -> Int? {
        trips(region: region, legs: legs, age: age).map { $0.reduce(0) { $0 + $1.fare } }
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = table.timeZone.flatMap(TimeZone.init(identifier:)) ?? .gmt
        return calendar
    }

    private func continues(_ previous: FareLeg, _ next: FareLeg, boardings: Int, in region: FareTable.Region) -> Bool {
        guard let transfer = region.transfer, boardings < transfer.maxBoardings ?? .max,
              let from = region.modes[previous.mode], let to = region.modes[next.mode] else { return false }
        // 개찰구를 나와 같은 종류(지하철→지하철)를 다시 타면 환승이 아니다.
        if from.kind == to.kind, from.transfersToSameKind == false || to.transfersToSameKind == false { return false }
        let gap = next.boardedAt.timeIntervalSince(previous.alightedAt)
        return gap >= 0 && gap <= Double(window(transfer, at: previous.alightedAt)) * 60
    }

    private func window(_ transfer: FareTable.Transfer, at date: Date) -> Int {
        guard let night = transfer.nightWindowMinutes, let start = transfer.nightStartHour, let end = transfer.nightEndHour else {
            return transfer.windowMinutes
        }
        let hour = calendar.component(.hour, from: date)
        return hour >= start || hour < end ? night : transfer.windowMinutes
    }

    private func fare(of group: [FareLeg], region: String, in regionTable: FareTable.Region, age: FareAgeBand) -> Int? {
        if group.count == 1, let leg = group.first {
            return fare(region: region, mode: leg.mode, distanceKm: leg.distanceKm, age: age)
        }
        var highest: FareTable.Amount?
        var baseKm = 0.0
        var total = 0
        for leg in group {
            guard let mode = regionTable.modes[leg.mode], let amount = mode.fares[age.rawValue],
                  let meters = Self.meters(leg.distanceKm) else { return nil }
            if amount.base > highest?.base ?? -1 { highest = amount }
            baseKm = max(baseKm, mode.transferBaseKm ?? 0)
            total += meters
        }
        guard let highest else { return nil }
        guard let unitKm = regionTable.transfer?.unitKm else { return highest.base }
        let band = FareTable.DistanceBand(fromKm: baseKm, toKm: nil, unitKm: unitKm)
        return highest.base + (highest.extra ?? 0) * Self.steps(meters: total, band: band)
    }

    /// 소수 오차를 피하려고 미터 정수로 센다.
    private static func meters(_ km: Double) -> Int? {
        guard km.isFinite, km >= 0, km < 100_000 else { return nil }
        return Int((km * 1_000).rounded())
    }

    /// 구간 안에서 넘은 거리를 단위 거리로 올림한 단계 수.
    private static func steps(meters: Int, band: FareTable.DistanceBand) -> Int {
        guard let from = Self.meters(band.fromKm), let unit = Self.meters(band.unitKm), unit > 0 else { return 0 }
        let upper = band.toKm.flatMap(Self.meters).map { min($0, meters) } ?? meters
        let over = upper - from
        return over > 0 ? (over + unit - 1) / unit : 0
    }
}
