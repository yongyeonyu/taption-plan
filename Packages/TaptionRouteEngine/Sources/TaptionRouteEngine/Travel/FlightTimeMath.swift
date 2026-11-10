import Foundation

/// 시간대가 붙지 않은 현지 벽시계 시각.
public struct FlightLocalTime: Hashable, Sendable {
    public let year: Int
    public let month: Int
    public let day: Int
    public let hour: Int
    public let minute: Int

    public init(year: Int, month: Int, day: Int, hour: Int, minute: Int) {
        self.year = year
        self.month = month
        self.day = day
        self.hour = hour
        self.minute = minute
    }
}

public struct FlightArrival: Hashable, Sendable {
    public let instant: Date
    public let local: FlightLocalTime
    /// 도착 현지 날짜가 출발 현지 날짜보다 며칠 뒤인가(날짜변경선을 동쪽으로 넘으면 0이나 음수도 된다).
    public let dayOffset: Int
}

/// 출발 현지 시각 → UTC → 비행 시간 → 도착 현지 시각. 서머타임·날짜변경선은 IANA 시간대가 처리한다.
public enum FlightTimeMath {
    public static func arrival(departure: FlightLocalTime, departureZone: String, durationMinutes: Int, arrivalZone: String) -> FlightArrival? {
        guard durationMinutes >= 0, let start = instant(departure, zone: departureZone),
              let zone = TimeZone(identifier: arrivalZone) else { return nil }
        let end = start.addingTimeInterval(Double(durationMinutes) * 60)
        let parts = calendar(zone).dateComponents([.year, .month, .day, .hour, .minute], from: end)
        guard let year = parts.year, let month = parts.month, let day = parts.day, let hour = parts.hour, let minute = parts.minute else { return nil }
        let local = FlightLocalTime(year: year, month: month, day: day, hour: hour, minute: minute)
        guard let offset = dayOffset(from: departure, to: local) else { return nil }
        return FlightArrival(instant: end, local: local, dayOffset: offset)
    }

    /// 두 현지 시각 사이의 실제 비행 시간(분).
    public static func durationMinutes(departure: FlightLocalTime, departureZone: String, arrival: FlightLocalTime, arrivalZone: String) -> Int? {
        guard let start = instant(departure, zone: departureZone), let end = instant(arrival, zone: arrivalZone) else { return nil }
        return Int((end.timeIntervalSince(start) / 60).rounded())
    }

    /// 없는 시각(서머타임으로 건너뛴 시각)이나 모르는 시간대면 nil.
    public static func instant(_ local: FlightLocalTime, zone identifier: String) -> Date? {
        guard let zone = TimeZone(identifier: identifier) else { return nil }
        let calendar = calendar(zone)
        let parts = DateComponents(year: local.year, month: local.month, day: local.day, hour: local.hour, minute: local.minute)
        guard parts.isValidDate(in: calendar), let date = calendar.date(from: parts) else { return nil }
        let back = calendar.dateComponents([.hour, .minute], from: date)
        return back.hour == local.hour && back.minute == local.minute ? date : nil
    }

    private static func calendar(_ zone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    private static func dayOffset(from start: FlightLocalTime, to end: FlightLocalTime) -> Int? {
        let calendar = calendar(.gmt)
        guard let first = calendar.date(from: DateComponents(year: start.year, month: start.month, day: start.day)),
              let last = calendar.date(from: DateComponents(year: end.year, month: end.month, day: end.day)) else { return nil }
        return calendar.dateComponents([.day], from: first, to: last).day
    }
}
