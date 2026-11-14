import Foundation
import simd

/// GPS 로그만 다른 앱이 읽는 GPX 1.1로 내보낸다(PLN1111A01 제안 2-8).
/// 위도·경도·고도·시각만 담는다. 활동·수단·역 이름·와이파이·건강·가계부·메모는 넣지 않는다.
enum GPXTrackExport {
    struct Point: Equatable {
        var latitude: Double
        var longitude: Double
        var altitude: Double?
        var time: Date
    }

    /// 기록이 이만큼 끊기면 구간(`<trkseg>`)을 나눈다.
    static let segmentGap: TimeInterval = 5 * 60

    /// 위치가 있는 표본만 시간 순서로. 같은 시각의 표본은 하나만 남긴다.
    static func points(from readings: [SensorReading]) -> [Point] {
        var result: [Point] = []
        for reading in readings.sorted(by: { $0.timestamp < $1.timestamp }) {
            guard let point = reading.point, point.latitude.isFinite, point.longitude.isFinite,
                  (-90...90).contains(point.latitude), (-180...180).contains(point.longitude),
                  !(point.latitude == 0 && point.longitude == 0), point.horizontalAccuracy >= 0 else { continue }
            if let last = result.last, last.time == reading.timestamp { continue }
            // 세로 정확도가 음수면 고도 값이 없다는 뜻이다.
            let altitude = point.verticalAccuracy >= 0 && point.altitude.isFinite ? point.altitude : nil
            result.append(Point(latitude: point.latitude, longitude: point.longitude, altitude: altitude, time: reading.timestamp))
        }
        return result
    }

    static func segments(_ points: [Point]) -> [[Point]] {
        var result: [[Point]] = []
        for point in points {
            if let last = result.last?.last, point.time.timeIntervalSince(last.time) <= segmentGap {
                result[result.count - 1].append(point)
            } else {
                result.append([point])
            }
        }
        return result
    }

    /// 이름에는 날짜 범위만 쓴다.
    static func document(_ points: [Point], name: String) -> String {
        // 시각은 UTC로 적는다(GPX 규격). 포매터는 파일 하나를 만드는 동안만 쓴다.
        let timeFormatter = ISO8601DateFormatter()
        timeFormatter.formatOptions = [.withInternetDateTime]
        timeFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        var lines = [
            #"<?xml version="1.0" encoding="UTF-8"?>"#,
            #"<gpx version="1.1" creator="BOKKI Plan" xmlns="http://www.topografix.com/GPX/1/1">"#,
            "  <trk>",
            "    <name>\(escaped(name))</name>",
        ]
        for segment in segments(points) {
            lines.append("    <trkseg>")
            for point in segment {
                let position = String(format: #"lat="%.7f" lon="%.7f""#, locale: posix, point.latitude, point.longitude)
                let elevation = point.altitude.map { String(format: "<ele>%.1f</ele>", locale: posix, $0) } ?? ""
                lines.append("      <trkpt \(position)>\(elevation)<time>\(timeFormatter.string(from: point.time))</time></trkpt>")
            }
            lines.append("    </trkseg>")
        }
        lines += ["  </trk>", "</gpx>", ""]
        return lines.joined(separator: "\n")
    }

    private static let posix = Locale(identifier: "en_US_POSIX")

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}

extension GPXTrackExport {
    /// 표본을 걸러 파일로 쓴다. 한 달 치는 표본이 많으니 메인 스레드 밖에서 돈다(메인 액터에 묶이지 않은 async 함수).
    static func write(_ readings: [SensorReading], name: String) async throws -> (url: URL, pointCount: Int) {
        let points = points(from: readings)
        let text = document(points, name: name)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TaptionPlanGPXExport", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("BOKKI-GPS-\(name).gpx")
        try Data(text.utf8).write(to: url, options: [.atomic, .completeFileProtection])
        return (url, points.count)
    }
}

extension GPXTrackExport {
    /// 고른 기간의 미리보기(GPV1114A01): 점 수, 처음·마지막 시각, 이동 거리, 줄여 담은 자취.
    struct Preview: Equatable {
        var pointCount = 0
        var first: Date?
        var last: Date?
        var meters = 0.0
        /// 구간별 (경도, 위도). 그림용으로 줄인 것이다.
        var track: [[SIMD2<Double>]] = []
    }

    static func preview(_ points: [Point], maxPoints: Int = 600) -> Preview {
        let parts = segments(points)
        var meters = 0.0
        for part in parts {
            for (a, b) in zip(part, part.dropFirst()) { meters += distance(a, b) }
        }
        let step = max(1, points.count / max(1, maxPoints))
        let track = parts.map { part in
            part.enumerated().filter { $0.offset % step == 0 || $0.offset == part.count - 1 }.map { SIMD2($0.element.longitude, $0.element.latitude) }
        }
        return Preview(pointCount: points.count, first: points.first?.time, last: points.last?.time, meters: meters, track: track)
    }

    private static func distance(_ a: Point, _ b: Point) -> Double {
        let radians = Double.pi / 180
        let dLat = (b.latitude - a.latitude) * radians, dLon = (b.longitude - a.longitude) * radians
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(a.latitude * radians) * cos(b.latitude * radians) * sin(dLon / 2) * sin(dLon / 2)
        return 6_371_000 * 2 * atan2(sqrt(h), sqrt(1 - h))
    }

    /// 시작 날 0시부터 끝 날 24시까지(지금을 넘지 않게). 거꾸로 골라도 바로잡는다.
    static func span(from: Date, to: Date, now: Date, calendar: Calendar = .autoupdatingCurrent) -> TimeSpan {
        let first = calendar.startOfDay(for: min(from, to))
        let lastDay = calendar.startOfDay(for: max(from, to))
        let end = min(now, calendar.date(byAdding: .day, value: 1, to: lastDay) ?? now)
        return TimeSpan(start: min(first, end), end: end)
    }

    static func name(_ span: TimeSpan, calendar: Calendar = .autoupdatingCurrent) -> String {
        let formatter = DateFormatter()
        formatter.locale = posix
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let first = formatter.string(from: span.start), last = formatter.string(from: span.end.addingTimeInterval(-1))
        return first == last ? first : "\(first)_\(last)"
    }
}

extension AppModel {
    /// 고른 날짜 기간의 위치 기록을 GPX 파일로 만들고 미리보기를 함께 돌려준다.
    func exportGPX(from: Date, to: Date, now: Date = .now) async throws -> (url: URL, preview: GPXTrackExport.Preview) {
        let span = GPXTrackExport.span(from: from, to: to, now: now)
        let readings = try await sensorService?.archivedRouteReadings(in: span) ?? []
        let url = try await GPXTrackExport.write(readings, name: GPXTrackExport.name(span)).url
        return (url, GPXTrackExport.preview(GPXTrackExport.points(from: readings)))
    }
}
