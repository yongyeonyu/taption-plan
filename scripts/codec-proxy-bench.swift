// 저장소 코덱의 JSON 왕복 비용 대리 측정.
//
// 실제 `SensorReading`을 쓸 수 없어(앱 target 의존) 같은 모양의 56필드 구조체로
// `TaptionReadingRowCodec.row(for:)` / `reading(from:)`과 같은 4단계 JSON 경로를 재현한다.
// 절대값은 실제 코덱과 다르다. **경로 비용의 크기 차수**만 읽는다.
//
// 실행: swift scripts/codec-proxy-bench.swift 20000

import Foundation

struct ProxyReading: Codable {
    var id: String
    var timestamp: Double
    var lat: Double, lon: Double, alt: Double, hAcc: Double, vAcc: Double
    var fixQuality: String, speedMps: Double, speedAccMps: Double
    var courseDeg: Double, courseAccDeg: Double
    var motion: String, motionConf: String, gpsAvailable: Bool
    var sourceDevice: String, trackingSessionID: String, trackingKind: String
    var trackingAuto: Bool, sessionEnded: Bool, sequence: Int
    var nearbyStation: Bool, stationName: String, matchesRail: Bool
    var powerState: String, screenOn: Bool, behavior: String, stepCount: Int
    var relAltM: Double, pressureKpa: Double
    var dmN: Int, dmAccMeanG: Double, dmAccStdG: Double, dmAccPeakG: Double
    var dmRotMean: Double, dmRotStd: Double, dmRotPeak: Double
    var matchesTransit: Bool, frequentStops: Bool, rideHailing: Bool
    var nearAirport: Bool, nearPort: Bool, onWater: Bool
    var floorsUp: Int, floorsDown: Int, walkDistM: Double
    var paceSPerM: Double, cadenceHz: Double, systemFloor: Int
    var screenBrightness: Double, wifiSSID: String, behaviorConf: String
    var watchWorkout: String, watchAccX: Double, watchAccY: Double
    var watchAccZ: Double, watchAccStd: Double, watchJerk: Double
}

let columnCount = 56

func makeReading(_ i: Int) -> ProxyReading {
    ProxyReading(
        id: UUID().uuidString, timestamp: 1_767_225_600 + Double(i * 60),
        lat: 37.5 + Double(i % 100) / 10000, lon: 127.0 + Double(i % 100) / 10000,
        alt: 12, hAcc: 8, vAcc: 8, fixQuality: "gps", speedMps: 1.2, speedAccMps: 0.5,
        courseDeg: 90, courseAccDeg: 12, motion: "walking", motionConf: "high",
        gpsAvailable: true, sourceDevice: "iphone", trackingSessionID: "session-\(i / 1440)",
        trackingKind: "walk", trackingAuto: false, sessionEnded: false, sequence: i,
        nearbyStation: false, stationName: "", matchesRail: false, powerState: "unplugged",
        screenOn: false, behavior: "walking", stepCount: i % 500, relAltM: 2.5,
        pressureKpa: 101.3, dmN: 20, dmAccMeanG: 0.04, dmAccStdG: 0.02, dmAccPeakG: 0.3,
        dmRotMean: 0.1, dmRotStd: 0.05, dmRotPeak: 0.4, matchesTransit: false,
        frequentStops: false, rideHailing: false, nearAirport: false, nearPort: false,
        onWater: false, floorsUp: 0, floorsDown: 0, walkDistM: 12.5, paceSPerM: 0.7,
        cadenceHz: 1.8, systemFloor: 3, screenBrightness: 0.4, wifiSSID: "",
        behaviorConf: "medium", watchWorkout: "", watchAccX: 0.01, watchAccY: 0.02,
        watchAccZ: 0.98, watchAccStd: 0.03, watchJerk: 0.002
    )
}

let encoder = JSONEncoder()
let decoder = JSONDecoder()
var scratch = 0

/// `row(for:)`: encode → parse → 열로 펼치기(56열)
func writePath(_ reading: ProxyReading) throws -> [(String, Any)] {
    var object = try JSONSerialization.jsonObject(with: encoder.encode(reading)) as? [String: Any] ?? [:]
    object["id"] = nil
    object["timestamp"] = nil
    var values: [(String, Any)] = []
    values.reserveCapacity(columnCount)
    for (key, value) in object { values.append((key, value)) }
    return values
}

/// `reading(from:)`: 56열 → 사전 → 직렬화 → decode
func readPath(id: String, timestamp: Double, values: [(String, Any)]) throws -> ProxyReading {
    var object: [String: Any] = [:]
    object.reserveCapacity(columnCount + 2)
    object["id"] = id
    object["timestamp"] = timestamp
    for (key, value) in values { object[key] = value }
    let data = try JSONSerialization.data(withJSONObject: object)
    return try decoder.decode(ProxyReading.self, from: data)
}

let iterations = CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1]) ?? 20_000 : 20_000
let readings = (0..<iterations).map(makeReading)

// 예열
for reading in readings.prefix(200) {
    if let values = try? writePath(reading) { scratch += values.count }
}

// 단계별 분해. 어느 JSON 통과가 비싼지 본다.
var start = Date()
for reading in readings { scratch += (try! encoder.encode(reading)).count }
let encodeSeconds = Date().timeIntervalSince(start)

let encoded = readings.map { try! encoder.encode($0) }
start = Date()
for data in encoded { scratch += (try! decoder.decode(ProxyReading.self, from: data)).stepCount }
let decodeSeconds = Date().timeIntervalSince(start)

start = Date()
for data in encoded { scratch += (try! JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]).count }
let parseSeconds = Date().timeIntervalSince(start)

let dicts = encoded.map { try! JSONSerialization.jsonObject(with: $0) as? [String: Any] ?? [:] }
start = Date()
for object in dicts { scratch += (try! JSONSerialization.data(withJSONObject: object)).count }
let serializeSeconds = Date().timeIntervalSince(start)

start = Date()
for reading in readings { scratch += try! writePath(reading).count }
let writeSeconds = Date().timeIntervalSince(start)

start = Date()
for reading in readings {
    let values = try! writePath(reading)
    scratch += try! readPath(id: reading.id, timestamp: reading.timestamp, values: values).stepCount
}
let roundTripSeconds = Date().timeIntervalSince(start) - writeSeconds

func micros(_ seconds: TimeInterval) -> Double { seconds / Double(iterations) * 1_000_000 }
print(String(format: "행 수: %d", iterations))
print(String(format: "  1 JSONEncoder.encode       %6.1f µs/행", micros(encodeSeconds)))
print(String(format: "  2 JSONDecoder.decode       %6.1f µs/행", micros(decodeSeconds)))
print(String(format: "  3 JSONSerialization.parse  %6.1f µs/행", micros(parseSeconds)))
print(String(format: "  4 JSONSerialization.data   %6.1f µs/행", micros(serializeSeconds)))
print(String(format: "  쓰기 경로(1+3)             %6.1f µs/행", micros(writeSeconds)))
print(String(format: "  왕복(1+3+4+2)              %6.1f µs/행", micros(roundTripSeconds)))
print(String(format: "  525,600행 왕복 추정: %.1f초 (대리 측정)", micros(roundTripSeconds) * 525_600 / 1_000_000))
print("scratch=\(scratch)")
