import Foundation

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

extension AppModel {
    /// 오늘부터 거슬러 `days`일의 위치 기록을 GPX 파일로 만든다. 기기에 남아 있는 기록만 나온다.
    func exportGPXURL(days: Int, now: Date = .now) async throws -> (url: URL, pointCount: Int) {
        let calendar = Calendar.autoupdatingCurrent
        let start = calendar.date(byAdding: .day, value: -(max(1, days) - 1), to: calendar.startOfDay(for: now)) ?? calendar.startOfDay(for: now)
        let readings = try await sensorService?.archivedRouteReadings(in: TimeSpan(start: start, end: now)) ?? []
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        let name = days <= 1 ? formatter.string(from: now) : "\(formatter.string(from: start))_\(formatter.string(from: now))"
        return try await GPXTrackExport.write(readings, name: name)
    }
}
