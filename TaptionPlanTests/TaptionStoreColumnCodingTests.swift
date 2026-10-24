import Foundation
import SQLite3
import XCTest
@testable import TaptionPlan

/// P1 코덱(`TaptionStoreColumnCoding`)이 예전 경로와 **같은 저장 형식**을 만드는지 확인한다.
///
/// 예전 경로는 행 하나에 JSON을 네 번 통과시켰다(`JSONEncoder` → `JSONSerialization` →
/// `JSONSerialization` → `JSONDecoder`). 새 경로는 `Codable` 컨테이너를 직접 구현해 같은 모양의
/// 사전을 바로 만든다. 저장 형식이 하나라도 달라지면 기존 파일을 읽을 수 없으므로,
/// 여기서 예전 구현을 테스트 안에 그대로 옮겨 두고 **행 단위로 비교**한다.
///
/// 한 가지 차이는 의도한 것이다: 예전 경로의 `JSONSerialization` **파서가 double을 몇 ULP 잘랐다**
/// (`0.019532305288943785` → `0.01953230528894378`, 표본 1,000행 최대 5 ULP). 그래서 열 값과
/// `extra` 텍스트가 마지막 비트에서 달라질 수 있고, 여기서는 그 차이만 허용한다
/// (`TaptionReadingRowCodec.sameReal`).
final class TaptionStoreColumnCodingTests: XCTestCase {
    private var root: URL!

    private var storeURL: URL { root.appendingPathComponent("store.sqlite") }

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("taption-codec-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        TaptionStoreQualityLedger.shared.reset()
    }

    override func tearDownWithError() throws {
        TaptionStoreQualityLedger.shared.reset()
        if let root { try? FileManager.default.removeItem(at: root) }
        try super.tearDownWithError()
    }

    // MARK: - 동등성

    func testColumnRowMatchesTheLegacyJSONPath() throws {
        let calendar = utcCalendar()
        var truncatedValues = 0
        for reading in Self.samples() {
            let legacy = try Self.legacyRow(for: reading, calendar: calendar)
            let fresh = try TaptionReadingRowCodec.row(for: reading, calendar: calendar)
            XCTAssertEqual(legacy.id, fresh.id)
            XCTAssertEqual(legacy.timestamp, fresh.timestamp)
            XCTAssertEqual(legacy.day, fresh.day)
            XCTAssertEqual(legacy.values.count, fresh.values.count)
            for (index, column) in TaptionReadingRowCodec.columns.enumerated() {
                let before = legacy.values[index]
                let after = fresh.values[index]
                guard case (.real(let left), .real(let right)) = (before, after) else {
                    XCTAssertEqual(before, after, "\(column.name) 값이 달라졌다")
                    continue
                }
                XCTAssertTrue(
                    TaptionReadingRowCodec.sameReal(left, right),
                    "\(column.name): legacy \(left) ≠ fresh \(right)"
                )
                if left != right {
                    truncatedValues += 1
                    // 표본 1,000행에서 잰 최대 차이는 5 ULP였다(상대오차 1.1e-15).
                    // 여유를 두되 "값이 달라진 것"과 구분되는 선에서 자른다.
                    XCTAssertLessThanOrEqual(
                        Self.ulpDistance(left, right), 16,
                        "\(column.name)의 차이가 16 ULP를 넘는다: \(left) vs \(right)"
                    )
                }
            }
        }
        XCTAssertGreaterThan(
            truncatedValues, 0,
            "예전 파서가 자른 값이 하나도 없다면 이 비교는 아무것도 증명하지 못한다"
        )
    }

    /// `extra`는 지금도 `JSONSerialization`으로 쓰고 읽는다(P1은 열 경로만 바꿨다).
    /// 그래서 **키 구조는 같고 값은 1 ULP 안에서 같아야** 한다. 텍스트가 같은 것은 아니다.
    func testExtraJSONKeepsTheSameShapeAndValues() throws {
        let calendar = utcCalendar()
        var compared = 0
        var textDifferences = 0
        for reading in Self.samples() {
            let legacy = try Self.legacyRow(for: reading, calendar: calendar).extra
            let fresh = try TaptionReadingRowCodec.row(for: reading, calendar: calendar).extra
            if legacy != fresh { textDifferences += 1 }
            guard let legacy, let fresh else {
                XCTAssertEqual(legacy, fresh, "한쪽만 extra가 있다")
                continue
            }
            let left = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: Data(legacy.utf8)) as? [String: Any]
            )
            let right = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: Data(fresh.utf8)) as? [String: Any]
            )
            XCTAssertEqual(left.keys.sorted(), right.keys.sorted(), "extra의 키가 달라졌다")
            XCTAssertTrue(Self.same(left, right), "extra 값이 1 ULP를 넘게 달라졌다: \(legacy) vs \(fresh)")
            compared += 1
        }
        XCTAssertGreaterThan(compared, 500, "extra가 비어 있으면 이 비교는 아무것도 증명하지 못한다")
        XCTAssertGreaterThan(
            textDifferences, 0,
            "예전 파서의 손실이 실제로 있었다면 텍스트도 달라져야 한다(허용 오차가 일하고 있다는 증거)"
        )
    }

    /// 열 값은 **정확히** 왕복해야 한다. `extra`만 예전과 같은 JSON 단계를 거치므로 1 ULP 손실이 남는다.
    func testRoundTripKeepsEveryColumnExactly() throws {
        let calendar = utcCalendar()
        for reading in Self.samples() {
            let row = try TaptionReadingRowCodec.row(for: reading, calendar: calendar)
            let restored = try TaptionReadingRowCodec.reading(from: row)
            let again = try TaptionReadingRowCodec.row(for: restored, calendar: calendar)
            XCTAssertEqual(row.values, again.values, "\(reading.id.uuidString)의 열 값이 왕복에서 달라졌다")
            XCTAssertEqual(row.timestamp, again.timestamp)
            XCTAssertEqual(row.day, again.day)
            XCTAssertTrue(
                TaptionReadingRowCodec.sameStoredContent(restored, reading),
                "왕복 결과가 원본과 같은 내용이 아니다: \(Self.describe(reading, restored))"
            )
        }
    }

    /// 56개 열 어디에서도 형태가 어긋나면 안 된다(어긋나면 값이 조용히 `extra`로 밀려난다).
    func testNoColumnIsDemotedForRealModelValues() throws {
        let calendar = utcCalendar()
        for reading in Self.samples() {
            _ = try TaptionReadingRowCodec.row(for: reading, calendar: calendar)
        }
        let demoted = TaptionStoreQualityLedger.shared.snapshot().demotedColumns
        XCTAssertTrue(demoted.isEmpty, "열 형태가 모델과 어긋난다: \(demoted)")
    }

    // MARK: - 예전 파일 읽기

    /// P1 이전에 쓰인 파일(= 예전 코덱이 만든 행)을 그대로 넣고, 새 코덱으로 읽어 본다.
    func testLegacyEncodedFileIsStillReadable() async throws {
        let calendar = utcCalendar()
        let store = try TaptionStoreV2(url: storeURL, calendar: calendar)
        let readings = Array(Self.samples().prefix(200))
        let legacyRows = try readings.map { try Self.legacyRow(for: $0, calendar: calendar) }
        try insert(legacyRows)

        let result = try await store.readingsLoadResult(
            from: Date(timeIntervalSince1970: 0),
            through: Date(timeIntervalSince1970: 4_000_000_000)
        )
        XCTAssertTrue(result.isComplete, "예전 파일이 해독되지 않았다")
        XCTAssertEqual(result.readings.count, readings.count)
        XCTAssertEqual(TaptionStoreQualityLedger.shared.snapshot().unreadableRows, 0)

        let byID = Dictionary(uniqueKeysWithValues: result.readings.map { ($0.id, $0) })
        for reading in readings {
            let stored = try XCTUnwrap(byID[reading.id], "\(reading.id.uuidString)가 없다")
            XCTAssertTrue(
                TaptionReadingRowCodec.sameStoredContent(stored, reading),
                "\(reading.id.uuidString)가 예전 파일에서 다르게 읽혔다: \(Self.describe(reading, stored))"
            )
        }
    }

    /// 새 코덱으로 쓴 파일을 새 코덱으로 읽는다(왕복이 파일까지 이어지는지).
    func testNewlyWrittenFileRoundTripsThroughTheStore() async throws {
        let calendar = utcCalendar()
        let store = try TaptionStoreV2(url: storeURL, calendar: calendar)
        let readings = Array(Self.samples().prefix(50))
        try await store.appendImmutableReadings(readings)
        let result = try await store.readingsLoadResult(
            from: Date(timeIntervalSince1970: 0),
            through: Date(timeIntervalSince1970: 4_000_000_000)
        )
        XCTAssertEqual(result.readings.count, readings.count)
        XCTAssertTrue(result.isComplete)
        let byID = Dictionary(uniqueKeysWithValues: result.readings.map { ($0.id, $0) })
        for reading in readings {
            let stored = try XCTUnwrap(byID[reading.id])
            XCTAssertTrue(TaptionReadingRowCodec.sameStoredContent(stored, reading))
        }
    }

    // MARK: - 충돌 판정

    /// 예전 파일에서 읽은 값과 원본은 **같은 내용**으로 판정돼야 한다.
    /// 아니면 복원할 때마다 "충돌 N건"이 뜬다(값은 1 ULP 차이로 사실상 같다).
    func testSameStoredContentToleratesTheLegacyTruncation() throws {
        let calendar = utcCalendar()
        for reading in Self.samples().prefix(300) {
            let row = try Self.legacyRow(for: reading, calendar: calendar)
            let restored = try TaptionReadingRowCodec.reading(from: row)
            XCTAssertTrue(
                TaptionReadingRowCodec.sameStoredContent(restored, reading),
                "\(reading.id.uuidString): \(Self.describe(reading, restored))"
            )
        }
    }

    /// 허용 오차가 실제 충돌을 삼키면 안 된다. 센서 값이 의미 있게 달라지면 충돌이다.
    func testSameStoredContentRejectsMeaningfulDifference() {
        let base = SensorReading(timestamp: Date(timeIntervalSince1970: 1000), speedMetersPerSecond: 1.5)
        let changed = SensorReading(
            id: base.id,
            timestamp: base.timestamp,
            speedMetersPerSecond: 1.5 + 1e-6
        )
        XCTAssertFalse(TaptionReadingRowCodec.sameStoredContent(base, changed))
        XCTAssertTrue(
            TaptionReadingRowCodec.sameStoredContent(
                base,
                SensorReading(id: base.id, timestamp: base.timestamp, speedMetersPerSecond: 1.5 + 1e-15)
            ),
            "표현 차이(1e-15)는 충돌이 아니다"
        )
    }

    // MARK: - 속도

    /// 예전 경로와 새 경로를 **같은 표본**으로 재서 비교한다. 대리 측정(`scripts/codec-proxy-bench.swift`)이
    /// 아니라 실제 `SensorReading`으로 잰 값이다. 시뮬레이터 수치라 절대값보다 배수만 읽는다.
    ///
    /// 실측(시뮬레이터, 1,000행, 최소 3회, 두 번 실행):
    /// 쓰기 164.6→136.9ms·130.1→108.1ms (**둘 다 1.20×**), 읽기 133.3→135.7ms·97.4→93.6ms (**0.98×·1.04× = 잡음**).
    /// **읽기는 빨라지지 않았다.** 대리 측정은 JSON 단계만 따로 쟀고, 행 경로의 나머지 비용
    /// (56열 `take`/`put`의 경로 문자열 분해, `[String: Any]` 복싱)은 두 경로가 똑같이 낸다.
    /// 그래서 여기서는 "쓰기가 의미 있게 빠를 것"과 "읽기가 눈에 띄게 느려지지 않을 것"만 단언한다.
    func testColumnCodecIsFasterThanTheLegacyJSONPath() throws {
        let calendar = utcCalendar()
        let readings = Array(Self.samples().prefix(1_000))

        // 예열: 첫 호출의 lazy 초기화·캐시를 측정에서 뺀다.
        _ = try readings.map { try Self.legacyRow(for: $0, calendar: calendar) }
        _ = try readings.map { try TaptionReadingRowCodec.row(for: $0, calendar: calendar) }

        let legacyWrite = try bestOf(3) {
            _ = try readings.map { try Self.legacyRow(for: $0, calendar: calendar) }
        }
        let freshWrite = try bestOf(3) {
            _ = try readings.map { try TaptionReadingRowCodec.row(for: $0, calendar: calendar) }
        }
        let legacyRows = try readings.map { try Self.legacyRow(for: $0, calendar: calendar) }
        let freshRows = try readings.map { try TaptionReadingRowCodec.row(for: $0, calendar: calendar) }
        let legacyRead = try bestOf(3) {
            for row in legacyRows { _ = try TaptionReadingRowCodec.reading(from: row) }
        }
        let freshRead = try bestOf(3) {
            for row in freshRows { _ = try TaptionReadingRowCodec.reading(from: row) }
        }

        let write = String(format: "%.1fms → %.1fms (%.2f×)", legacyWrite * 1_000, freshWrite * 1_000, legacyWrite / freshWrite)
        let read = String(format: "%.1fms → %.1fms (%.2f×)", legacyRead * 1_000, freshRead * 1_000, legacyRead / freshRead)
        print("codec 1,000행 쓰기 \(write), 읽기 \(read)")

        XCTAssertLessThan(freshWrite, legacyWrite * 0.95, "쓰기가 5% 이상 빠르지 않다: \(write)")
        XCTAssertLessThan(freshRead, legacyRead * 1.10, "읽기가 10% 넘게 느려졌다: \(read)")
    }

    /// 읽기 1,000행의 총 비용과 그중 `extra` 파싱 비중을 남긴다(진단용, 단언 없음).
    /// 사전을 없애고 행에서 바로 디코딩하므로, 남은 비용은 사실상 디코더 하나다.
    func testReadPathBreakdown() throws {
        let calendar = utcCalendar()
        let readings = Array(Self.samples().prefix(1_000))
        let rows = try readings.map { try TaptionReadingRowCodec.row(for: $0, calendar: calendar) }

        _ = try rows.map { try TaptionReadingRowCodec.reading(from: $0) } // 예열

        let total = try bestOf(3) {
            for row in rows { _ = try TaptionReadingRowCodec.reading(from: row) }
        }
        let extraParse = try bestOf(3) {
            for row in rows {
                guard let extra = row.extra else { continue }
                _ = try JSONSerialization.jsonObject(with: Data(extra.utf8)) as? [String: Any]
            }
        }

        func ms(_ value: TimeInterval) -> String { String(format: "%.1f", value * 1_000) }
        print(
            "read 1,000행: 전체 \(ms(total))ms (그중 extra 파싱 \(ms(extraParse))ms, "
            + "행→모델 \(ms(total - extraParse))ms)"
        )
    }

    /// 여러 번 재서 가장 빠른 값을 쓴다(스케줄링·GC 잡음에 덜 흔들린다).
    private func bestOf(_ rounds: Int, _ body: () throws -> Void) rethrows -> TimeInterval {
        var best = TimeInterval.greatestFiniteMagnitude
        for _ in 0..<rounds {
            let start = Date()
            try body()
            best = min(best, Date().timeIntervalSince(start))
        }
        return best
    }

    // MARK: - 예전과 같은 실패

    /// `JSONEncoder`는 무한대·NaN을 던진다. 새 코덱도 던져야 한다(조용히 0으로 바꾸면 값이 망가진다).
    func testNonFiniteValueThrowsLikeJSONEncoder() {
        let reading = SensorReading(
            timestamp: Date(timeIntervalSince1970: 1000),
            speedMetersPerSecond: .nan
        )
        XCTAssertThrowsError(try TaptionReadingRowCodec.row(for: reading, calendar: utcCalendar()))
    }

    // MARK: - 예전 구현 (테스트 안에만 있다)

    /// P1 이전 경로의 첫 단계: 모델 → JSON 텍스트 → 사전.
    private static func legacyObject(_ reading: SensorReading) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return try JSONSerialization.jsonObject(with: encoder.encode(reading)) as? [String: Any] ?? [:]
    }

    /// P1 이전 `TaptionStoreV2.row(for:)`와 같은 코드. 비교 기준으로만 쓴다.
    private static func legacyRow(
        for reading: SensorReading,
        calendar: Calendar
    ) throws -> TaptionReadingRowCodec.Row {
        var object = try legacyObject(reading)
        guard let id = object["id"] as? String, TaptionReadingRowCodec.uuidData(id) != nil,
              let timestamp = (object["timestamp"] as? NSNumber)?.doubleValue else {
            throw TaptionStoreV2Error.corruptRow("reading without a UUID id or timestamp")
        }
        object["id"] = nil
        object["timestamp"] = nil
        var values: [TaptionReadingRowCodec.Value] = []
        for column in TaptionReadingRowCodec.columns {
            values.append(TaptionReadingRowCodec.take(column, from: &object))
        }
        let extra: String? = object.isEmpty ? nil : String(
            decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
            as: UTF8.self
        )
        return TaptionReadingRowCodec.Row(
            id: id,
            timestamp: timestamp,
            day: TaptionReadingRowCodec.dayNumber(for: Date(timeIntervalSince1970: timestamp), calendar: calendar),
            values: values,
            extra: extra
        )
    }

    // MARK: - 표본

    /// 열 56개가 모두 채워지는 행과, 옵셔널이 비는 행을 섞는다. 값은 결정적이다(실패 재현용).
    private static func samples() -> [SensorReading] {
        var generator = SeededGenerator(state: 0x5EED_1024)
        let base = Date(timeIntervalSince1970: 1_767_297_600) // 2026-01-01 20:00 UTC
        return (0..<1_000).map { index in
            let whole = index % 7 == 0 // 정수값 Double을 섞어 JSON 표기 경계를 건드린다
            let speed = whole ? Double(generator.int(0...12)) : generator.double(0...12)
            let sparse = index % 5 == 0
            return SensorReading(
                id: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", index)) ?? UUID(),
                timestamp: base.addingTimeInterval(Double(index) * 60),
                point: sparse ? nil : GeoPoint(
                    latitude: 37.0 + generator.double(0...1),
                    longitude: 126.0 + generator.double(0...1),
                    altitude: generator.double(-10...120),
                    horizontalAccuracy: generator.double(1...60),
                    verticalAccuracy: generator.double(1...30)
                ),
                locationFixQuality: sparse ? nil : (generator.bool() ? .precise : .approximate),
                speedMetersPerSecond: sparse ? nil : speed,
                speedAccuracyMetersPerSecond: sparse ? nil : generator.double(0...3),
                courseDegrees: sparse ? nil : generator.double(0...360),
                courseAccuracyDegrees: sparse ? nil : generator.double(0...45),
                motion: MotionKind.allCases[generator.int(0...(MotionKind.allCases.count - 1))],
                motionConfidence: ConfidenceLevel.allCases[generator.int(0...(ConfidenceLevel.allCases.count - 1))],
                relativeAltitudeMeters: sparse ? nil : generator.double(-20...40),
                pressureKilopascals: sparse ? nil : generator.double(95...103),
                altimeterSessionID: sparse ? nil : UUID(),
                floorsAscended: sparse ? nil : generator.int(0...12),
                floorsDescended: sparse ? nil : generator.int(0...12),
                stepCount: sparse ? nil : generator.int(0...900),
                walkingRunningDistanceMeters: sparse ? nil : generator.double(0...1_500),
                currentPaceSecondsPerMeter: sparse ? nil : generator.double(0.3...2.5),
                currentCadenceStepsPerSecond: sparse ? nil : generator.double(0...4),
                // 정수값 Double이 `extra`에 어떻게 적히는지도 비교 대상이다.
                averageActivePaceSecondsPerMeter: sparse
                    ? nil
                    : (whole ? Double(generator.int(8...20)) : generator.double(0.3...2.5)),
                deviceMotion: sparse ? nil : DeviceMotionSnapshot(
                    gravity: SensorVector3(x: 0, y: 0, z: -1),
                    userAcceleration: SensorVector3(
                        x: generator.double(-2...2),
                        y: generator.double(-2...2),
                        z: generator.double(-2...2)
                    ),
                    rotationRate: SensorVector3(
                        x: generator.double(-4...4),
                        y: generator.double(-4...4),
                        z: generator.double(-4...4)
                    ),
                    attitudeRadians: SensorVector3(x: 0.1, y: 0.2, z: 0.3),
                    magneticFieldMicroteslas: generator.bool()
                        ? SensorVector3(x: 20, y: -5, z: 41.5)
                        : nil,
                    magneticFieldAccuracy: generator.bool() ? generator.int(0...3) : nil,
                    headingDegrees: generator.bool() ? generator.double(0...360) : nil
                ),
                deviceMotionSummary: sparse ? nil : DeviceMotionSummary(
                    sampleCount: generator.int(1...120),
                    meanUserAccelerationG: generator.double(0...1),
                    userAccelerationStandardDeviationG: generator.double(0...1),
                    peakUserAccelerationG: generator.double(0...3),
                    meanRotationRateRadiansPerSecond: generator.double(0...2),
                    rotationRateStandardDeviationRadiansPerSecond: generator.double(0...2),
                    peakRotationRateRadiansPerSecond: generator.double(0...5)
                ),
                watchAccelerationAverageG: sparse
                    ? nil
                    : SensorVector3(
                        x: generator.double(-1...1),
                        y: generator.double(-1...1),
                        z: generator.double(-1...1)
                    ),
                watchAccelerationStandardDeviationG: sparse ? nil : generator.double(0...1),
                watchAccelerationMeanJerkGPerSecond: sparse ? nil : generator.double(0...4),
                systemFloor: sparse ? nil : generator.int(-3...40),
                powerState: sparse ? nil : [DevicePowerState.unknown, .unplugged, .charging, .full][generator.int(0...3)],
                screenBrightness: sparse ? nil : generator.double(0...1),
                screenIsOn: sparse ? nil : generator.bool(),
                gpsAvailable: generator.bool(),
                connectedWiFiSSID: sparse ? nil : (generator.bool() ? "SKY_NET_5G" : nil),
                subwayWiFiObservationStreak: sparse ? nil : generator.int(0...9),
                nearbyStation: generator.bool(),
                nearbyStationName: sparse ? nil : ["강남", "역삼", "선릉"][generator.int(0...2)],
                matchesRailRoute: generator.bool(),
                matchesPublicTransitRoute: generator.bool(),
                frequentStops: generator.bool(),
                rideHailingHint: generator.bool(),
                nearAirport: generator.bool(),
                nearPort: generator.bool(),
                onWater: generator.bool(),
                watchWorkoutKind: sparse ? nil : ["walking", "running", "cycling"][generator.int(0...2)],
                behavior: sparse ? nil : ["walking", "riding", "waiting"][generator.int(0...2)],
                behaviorConfidenceScore: sparse ? nil : generator.double(0...1),
                behaviorEvidence: sparse ? nil : ["speed", "cadence", "wifi"].filter { _ in generator.bool() },
                behaviorModelVersion: sparse ? nil : "v3",
                trackingSessionID: sparse ? nil : UUID(),
                trackingKind: sparse ? nil : TrackingKind.allCases[generator.int(0...(TrackingKind.allCases.count - 1))],
                trackingWasAutomaticallyDetected: sparse ? nil : generator.bool(),
                sourceDevice: sparse ? nil : (generator.bool() ? .iPhone : .appleWatch),
                sequence: sparse ? nil : generator.int(0...100_000),
                trackingSessionEnded: sparse ? nil : generator.bool()
            )
        }
    }

    // MARK: - 비교 도우미

    /// 두 double 사이의 ULP 거리. 같은 부호끼리만 의미가 있다(여기서는 같은 값에서 나왔다).
    private static func ulpDistance(_ lhs: Double, _ rhs: Double) -> UInt64 {
        let left = lhs.bitPattern
        let right = rhs.bitPattern
        return left > right ? left - right : right - left
    }

    private static func same(_ lhs: Any?, _ rhs: Any?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case (_ as NSNull, _ as NSNull):
            return true
        case (let left as NSNumber, let right as NSNumber):
            let leftIsBool = CFGetTypeID(left) == CFBooleanGetTypeID()
            let rightIsBool = CFGetTypeID(right) == CFBooleanGetTypeID()
            guard leftIsBool == rightIsBool else { return false }
            return leftIsBool
                ? left.boolValue == right.boolValue
                : TaptionReadingRowCodec.sameReal(left.doubleValue, right.doubleValue)
        case (let left as String, let right as String):
            return left == right
        case (let left as [Any], let right as [Any]):
            return left.count == right.count && zip(left, right).allSatisfy { same($0, $1) }
        case (let left as [String: Any], let right as [String: Any]):
            return left.keys.sorted() == right.keys.sorted() && left.allSatisfy { same($0.value, right[$0.key]) }
        default:
            return false
        }
    }

    /// 모델 두 개의 차이를 필드 이름으로 알려 준다. `XCTAssertEqual`의 전체 덤프는 눈으로 못 읽는다.
    private static func describe(_ original: SensorReading, _ restored: SensorReading) -> String {
        guard let left = try? legacyObject(original), let right = try? legacyObject(restored) else {
            return "사전을 만들지 못했다"
        }
        var differences: [String] = []
        for key in Set(left.keys).union(right.keys).sorted() where !same(left[key], right[key]) {
            differences.append("\(key): \(text(left[key])) → \(text(right[key]))")
        }
        return differences.isEmpty ? "사전은 같은데 모델이 다르다" : differences.joined(separator: ", ")
    }

    private static func text(_ value: Any?) -> String {
        guard let value else { return "nil" }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            return "\(number.doubleValue)"
        }
        return "\(value)"
    }

    // MARK: - 저장소 도우미

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// 예전 코덱이 만든 행을 저장소 밖에서 직접 넣는다(P1 이전 파일을 흉내 낸다).
    private func insert(_ rows: [TaptionReadingRowCodec.Row]) throws {
        var db: OpaquePointer?
        guard sqlite3_open(storeURL.path, &db) == SQLITE_OK else {
            throw TaptionStoreV2Error.openFailed(storeURL.path)
        }
        defer { sqlite3_close(db) }
        let names = TaptionReadingRowCodec.columns.map(\.name)
        let columnList = (["id", "ts", "day"] + names + ["extra"]).joined(separator: ", ")
        let placeholders = Array(repeating: "?", count: names.count + 4).joined(separator: ", ")
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            db, "INSERT INTO readings (\(columnList)) VALUES (\(placeholders))", -1, &statement, nil
        ) == SQLITE_OK else {
            throw TaptionStoreV2Error.sqlFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        for row in rows {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            guard let id = TaptionReadingRowCodec.uuidData(row.id) else {
                throw TaptionStoreV2Error.corruptRow("id is not a UUID: \(row.id)")
            }
            id.withUnsafeBytes { buffer in
                _ = sqlite3_bind_blob(statement, 1, buffer.baseAddress, Int32(buffer.count), Self.transient)
            }
            sqlite3_bind_double(statement, 2, row.timestamp)
            sqlite3_bind_int64(statement, 3, Int64(row.day))
            for (index, value) in row.values.enumerated() {
                let position = Int32(index + 4)
                switch value {
                case .null:
                    sqlite3_bind_null(statement, position)
                case .int(let number):
                    sqlite3_bind_int64(statement, position, number)
                case .real(let number):
                    sqlite3_bind_double(statement, position, number)
                case .text(let text):
                    sqlite3_bind_text(statement, position, text, -1, Self.transient)
                case .blob(let data):
                    data.withUnsafeBytes { buffer in
                        _ = sqlite3_bind_blob(statement, position, buffer.baseAddress, Int32(buffer.count), Self.transient)
                    }
                }
            }
            let extraPosition = Int32(row.values.count + 4)
            if let extra = row.extra {
                sqlite3_bind_text(statement, extraPosition, extra, -1, Self.transient)
            } else {
                sqlite3_bind_null(statement, extraPosition)
            }
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw TaptionStoreV2Error.sqlFailed(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar
    }
}

/// 결정적 난수. 표본이 매번 같아야 실패를 다시 만들 수 있다.
private struct SeededGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }

    mutating func double(_ range: ClosedRange<Double>) -> Double {
        let unit = Double(next() >> 11) / Double(1 << 53)
        return range.lowerBound + unit * (range.upperBound - range.lowerBound)
    }

    mutating func int(_ range: ClosedRange<Int>) -> Int {
        let span = UInt64(range.upperBound - range.lowerBound + 1)
        return range.lowerBound + Int(next() % span)
    }

    mutating func bool() -> Bool { next() % 2 == 0 }
}
