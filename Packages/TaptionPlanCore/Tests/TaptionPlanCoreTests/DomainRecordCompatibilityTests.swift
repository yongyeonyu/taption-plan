import Foundation
import Testing
@testable import TaptionPlanCore

/// 앱 타깃에서 옮겨 온 도메인 타입의 저장 바이트 계약.
/// 기대 JSON은 옮기기 전 앱 선언으로 인코딩한 결과다(`build/validation/RFA1102A01/phase2`).
/// 저장소·백업과 같은 설정(`secondsSince1970`, `sortedKeys`)과 기본 설정을 함께 고정한다.
struct DomainRecordCompatibilityTests {
    static let storeEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static let storeDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()

    static func defaultEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    /// 기대 바이트를 읽고 다시 쓰면 바이트가 같아야 한다.
    static func roundTrip<T: Codable & Equatable>(
        _ type: T.Type, stored json: String, expected value: T
    ) throws {
        let decoded = try storeDecoder.decode(T.self, from: Data(json.utf8))
        #expect(decoded == value)
        let encoded = String(decoding: try storeEncoder.encode(decoded), as: UTF8.self)
        #expect(encoded == json)
    }

    static let start = Date(timeIntervalSince1970: 1_762_560_000)

    @Test func timeSpanStoredBytesAreUnchanged() throws {
        let span = TimeSpan(start: Self.start, end: Self.start.addingTimeInterval(3_600))
        try Self.roundTrip(TimeSpan.self, stored: #"{"end":1762563600,"start":1762560000}"#, expected: span)
        let deferred = String(decoding: try Self.defaultEncoder().encode(span), as: UTF8.self)
        #expect(deferred == #"{"end":784256400,"start":784252800}"#)
    }

    @Test func timeSpanKeepsEndNotBeforeStart() {
        let span = TimeSpan(start: Self.start, end: Self.start.addingTimeInterval(-10))
        #expect(span.end == span.start)
        #expect(span.duration == 0)
    }

    @Test func activityCorrectionStoredBytesAreUnchanged() throws {
        try Self.roundTrip(
            ActivityCorrection.self,
            stored: #"{"behavior":"brushing","categoryID":"activity","endedAt":1762560120,"startedAt":1762560000,"title":"양치"}"#,
            expected: ActivityCorrection(
                title: "양치", behavior: "brushing", categoryID: "activity",
                startedAt: Self.start, endedAt: Self.start.addingTimeInterval(120)
            )
        )
        try Self.roundTrip(
            ActivityCorrection.self,
            stored: #"{"categoryID":"activity","title":"독서"}"#,
            expected: ActivityCorrection(title: "독서")
        )
    }

    static func id(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
    }

    @Test func actualRecordStoredBytesAreUnchanged() throws {
        let full = ActualRecord(
            id: Self.id(1), planID: Self.id(2), routineID: Self.id(3), title: "걷기",
            categoryID: "movement", startedAt: Self.start, endedAt: Self.start.addingTimeInterval(900),
            source: .motion, confidence: .medium, createdAt: Self.start.addingTimeInterval(901),
            behavior: "walking", evidence: ["steps", "gps"], routeID: Self.id(4), sensorChunkID: Self.id(5),
            modelVersion: "m7", manuallyCorrected: true, isClassificationLocked: false,
            classificationScore: 0.625, lockReason: .user
        )
        try Self.roundTrip(
            ActualRecord.self,
            stored: #"{"behavior":"walking","categoryID":"movement","classificationScore":0.625,"confidence":"medium","createdAt":1762560901,"endedAt":1762560900,"evidence":["steps","gps"],"id":"00000000-0000-0000-0000-000000000001","isClassificationLocked":false,"lockReason":"user","manuallyCorrected":true,"modelVersion":"m7","planID":"00000000-0000-0000-0000-000000000002","routeID":"00000000-0000-0000-0000-000000000004","routineID":"00000000-0000-0000-0000-000000000003","sensorChunkID":"00000000-0000-0000-0000-000000000005","source":"motion","startedAt":1762560000,"title":"걷기"}"#,
            expected: full
        )
        let minimal = ActualRecord(
            id: Self.id(6), planID: nil, title: "메모", categoryID: "activity",
            startedAt: Self.start, source: .manual, createdAt: Self.start
        )
        try Self.roundTrip(
            ActualRecord.self,
            stored: #"{"categoryID":"activity","confidence":"high","createdAt":1762560000,"evidence":[],"id":"00000000-0000-0000-0000-000000000006","isClassificationLocked":false,"manuallyCorrected":false,"source":"manual","startedAt":1762560000,"title":"메모"}"#,
            expected: minimal
        )
    }

    /// 예전 기록(근거·교정·잠금 키 없음)은 기본값으로 읽히고, 자동 원천은 잠긴다.
    @Test func legacyActualRecordDecodesWithDefaults() throws {
        let legacy = #"{"categoryID":"location","confidence":"high","createdAt":1762560000,"id":"00000000-0000-0000-0000-000000000009","source":"location","startedAt":1762560000,"title":"집"}"#
        let decoded = try Self.storeDecoder.decode(ActualRecord.self, from: Data(legacy.utf8))
        let encoded = String(decoding: try Self.storeEncoder.encode(decoded), as: UTF8.self)
        #expect(encoded == #"{"categoryID":"location","confidence":"high","createdAt":1762560000,"evidence":[],"id":"00000000-0000-0000-0000-000000000009","isClassificationLocked":true,"manuallyCorrected":false,"source":"location","startedAt":1762560000,"title":"집"}"#)
    }

    @Test func planRecordStoredBytesAreUnchanged() throws {
        let rule = GoalRepeatRule(id: Self.id(4), name: "아침", weekdays: [2], startMinuteOfDay: 420, endMinuteOfDay: 480)
        let full = PlanRecord(
            id: Self.id(1), title: "루틴:운동",
            span: TimeSpan(start: Self.start, end: Self.start.addingTimeInterval(3_600)),
            categoryID: "activity", middleCategoryName: "운동", subCategoryName: "달리기",
            repeatRules: [rule], parentID: Self.id(2), status: .completed, origin: .repeatRule,
            isFixed: true, isImportant: true, externalCalendarID: "cal", externalEventID: "evt",
            createdAt: Self.start, updatedAt: Self.start.addingTimeInterval(60)
        )
        try Self.roundTrip(
            PlanRecord.self,
            stored: #"{"categoryID":"activity","createdAt":1762560000,"externalCalendarID":"cal","externalEventID":"evt","id":"00000000-0000-0000-0000-000000000001","isFixed":true,"isImportant":true,"middleCategoryName":"운동","origin":"repeatRule","parentID":"00000000-0000-0000-0000-000000000002","repeatRules":[{"endMinuteOfDay":480,"id":"00000000-0000-0000-0000-000000000004","name":"아침","startMinuteOfDay":420,"weekdays":[2]}],"span":{"end":1762563600,"start":1762560000},"status":"completed","subCategoryName":"달리기","title":"루틴:운동","updatedAt":1762560060}"#,
            expected: full
        )
        // 빈 반복 규칙은 저장하지 않는다(nil로 접는다).
        let plain = PlanRecord(
            id: Self.id(3), title: "회의", span: TimeSpan(start: Self.start, end: Self.start),
            categoryID: "work", repeatRules: [], createdAt: Self.start, updatedAt: Self.start
        )
        try Self.roundTrip(
            PlanRecord.self,
            stored: #"{"categoryID":"work","createdAt":1762560000,"id":"00000000-0000-0000-0000-000000000003","isFixed":false,"isImportant":false,"origin":"user","span":{"end":1762560000,"start":1762560000},"status":"planned","title":"회의","updatedAt":1762560000}"#,
            expected: plain
        )
    }

    /// PLB1114A18: 장소·예상 지출은 있을 때만 키를 쓰고, 그 키가 없는 예전 기록은 그대로 읽히고 다시 써도 바이트가 같다.
    @Test func planRecordPlaceAndPlannedSpendAreOptionalKeys() throws {
        let placed = PlanRecord(
            id: Self.id(5), title: "저녁", span: TimeSpan(start: Self.start, end: Self.start.addingTimeInterval(3_600)),
            categoryID: "activity", createdAt: Self.start, updatedAt: Self.start,
            place: PlanPlace(name: "식당", latitude: 0.5, longitude: 0.25), plannedSpendKRW: 30_000
        )
        try Self.roundTrip(
            PlanRecord.self,
            stored: #"{"categoryID":"activity","createdAt":1762560000,"id":"00000000-0000-0000-0000-000000000005","isFixed":false,"isImportant":false,"origin":"user","place":{"latitude":0.5,"longitude":0.25,"name":"식당"},"plannedSpendKRW":30000,"span":{"end":1762563600,"start":1762560000},"status":"planned","title":"저녁","updatedAt":1762560000}"#,
            expected: placed
        )
        let legacy = #"{"categoryID":"work","createdAt":1762560000,"id":"00000000-0000-0000-0000-000000000003","isFixed":false,"isImportant":false,"origin":"user","span":{"end":1762560000,"start":1762560000},"status":"planned","title":"회의","updatedAt":1762560000}"#
        let decoded = try Self.storeDecoder.decode(PlanRecord.self, from: Data(legacy.utf8))
        #expect(decoded.place == nil)
        #expect(decoded.plannedSpendKRW == nil)
        #expect(String(decoding: try Self.storeEncoder.encode(decoded), as: UTF8.self) == legacy)
    }

    @Test func geoPointStoredBytesAreUnchanged() throws {
        try Self.roundTrip(
            GeoPoint.self,
            stored: #"{"altitude":12.5,"horizontalAccuracy":5,"latitude":37.5,"longitude":127.25,"verticalAccuracy":-1}"#,
            expected: GeoPoint(latitude: 37.5, longitude: 127.25, altitude: 12.5, horizontalAccuracy: 5, verticalAccuracy: -1)
        )
    }

    @Test func travelSegmentStoredBytesAreUnchanged() throws {
        let route = SubwayRoutePath(
            stops: [
                SubwayRouteStop(lineName: "2호선", order: 1, stationName: "강남", latitude: 37.5, longitude: 127.0),
                SubwayRouteStop(lineName: "2호선", order: 2, stationName: "역삼", latitude: nil, longitude: nil),
            ],
            lineNames: ["2호선"], transferStationNames: []
        )
        let subway = TravelSegment(
            id: Self.id(1), fromPlaceID: Self.id(2), toPlaceID: Self.id(3), mode: .subway,
            span: TimeSpan(start: Self.start, end: Self.start.addingTimeInterval(600)),
            distanceMeters: 1_234.5, confidence: .high, evidence: ["wifi"], isConfirmed: true,
            subwayRoute: route, isClassificationLocked: true
        )
        try Self.roundTrip(
            TravelSegment.self,
            stored: #"{"confidence":"high","distanceMeters":1234.5,"evidence":["wifi"],"fromPlaceID":"00000000-0000-0000-0000-000000000002","id":"00000000-0000-0000-0000-000000000001","isClassificationLocked":true,"isConfirmed":true,"mode":"subway","span":{"end":1762560600,"start":1762560000},"subwayRoute":{"lineNames":["2호선"],"stops":[{"latitude":37.5,"lineName":"2호선","longitude":127,"order":1,"stationName":"강남"},{"lineName":"2호선","order":2,"stationName":"역삼"}],"transferStationNames":[]},"toPlaceID":"00000000-0000-0000-0000-000000000003"}"#,
            expected: subway
        )
        // 음수 거리는 0으로 접는다.
        let walk = TravelSegment(
            id: Self.id(4), mode: .walking, span: TimeSpan(start: Self.start, end: Self.start),
            distanceMeters: -3, confidence: .low, evidence: []
        )
        try Self.roundTrip(
            TravelSegment.self,
            stored: #"{"confidence":"low","distanceMeters":0,"evidence":[],"id":"00000000-0000-0000-0000-000000000004","isClassificationLocked":false,"isConfirmed":false,"mode":"walking","span":{"end":1762560000,"start":1762560000}}"#,
            expected: walk
        )
    }

    /// 예전 이동 기록(거리·근거·확인·잠금 키 없음)은 잠긴 자동 분류로 읽힌다.
    @Test func legacyTravelSegmentDecodesLocked() throws {
        let legacy = #"{"confidence":"medium","id":"00000000-0000-0000-0000-000000000009","mode":"bus","span":{"end":1762560600,"start":1762560000}}"#
        let decoded = try Self.storeDecoder.decode(TravelSegment.self, from: Data(legacy.utf8))
        let encoded = String(decoding: try Self.storeEncoder.encode(decoded), as: UTF8.self)
        #expect(encoded == #"{"confidence":"medium","distanceMeters":0,"evidence":[],"id":"00000000-0000-0000-0000-000000000009","isClassificationLocked":true,"isConfirmed":false,"mode":"bus","span":{"end":1762560600,"start":1762560000}}"#)
    }

    static let sensorStart = Date(timeIntervalSince1970: 1_762_560_000.25)

    /// 센서 원본은 열 코덱(JSON 키)과 TSR2 이진 형식 둘 다 고정한다.
    @Test func sensorReadingStoredBytesAreUnchanged() throws {
        let v = SensorVector3(x: 0.5, y: -0.25, z: 1)
        let full = SensorReading(id: Self.id(1), timestamp: Self.sensorStart, point: GeoPoint(latitude: 37.5, longitude: 127.25, altitude: 12.5, horizontalAccuracy: 5, verticalAccuracy: 3), locationFixQuality: .precise, speedMetersPerSecond: 1.5, speedAccuracyMetersPerSecond: 0.5, courseDegrees: 90, courseAccuracyDegrees: 10, motion: .walking, motionConfidence: .high, relativeAltitudeMeters: 2.5, pressureKilopascals: 101.25, altimeterSessionID: Self.id(2), floorsAscended: 1, floorsDescended: 0, stepCount: 42, walkingRunningDistanceMeters: 30.5, currentPaceSecondsPerMeter: 0.75, currentCadenceStepsPerSecond: 1.75, averageActivePaceSecondsPerMeter: 0.8, deviceMotion: DeviceMotionSnapshot(gravity: v, userAcceleration: v, rotationRate: v, attitudeRadians: v, magneticFieldMicroteslas: v, magneticFieldAccuracy: 2, headingDegrees: 45), deviceMotionSummary: DeviceMotionSummary(sampleCount: 50, meanUserAccelerationG: 0.1, userAccelerationStandardDeviationG: 0.2, peakUserAccelerationG: 0.5, meanRotationRateRadiansPerSecond: 0.25, rotationRateStandardDeviationRadiansPerSecond: 0.125, peakRotationRateRadiansPerSecond: 1), watchAccelerationAverageG: v, watchAccelerationStandardDeviationG: 0.25, watchAccelerationMeanJerkGPerSecond: 0.5, systemFloor: 3, powerState: .charging, screenBrightness: 1.5, screenIsOn: true, gpsAvailable: false, connectedWiFiSSID: "wifi", subwayWiFiObservationStreak: -2, nearbyStation: true, nearbyStationName: "강남", matchesRailRoute: true, matchesPublicTransitRoute: true, frequentStops: true, rideHailingHint: true, nearAirport: true, nearPort: true, onWater: true, watchWorkoutKind: "walk", behavior: "walking", behaviorConfidenceScore: 0.875, behaviorEvidence: ["a"], behaviorModelVersion: "b1", trackingSessionID: Self.id(3), trackingKind: .running, trackingWasAutomaticallyDetected: true, sourceDevice: .appleWatch, sequence: 7, trackingSessionEnded: false, carAudioRouteName: "car")
        let minimal = SensorReading(id: Self.id(4), timestamp: Self.sensorStart)
        try Self.roundTrip(SensorReading.self, stored: #"{"altimeterSessionID":"00000000-0000-0000-0000-000000000002","averageActivePaceSecondsPerMeter":0.8,"behavior":"walking","behaviorConfidenceScore":0.875,"behaviorEvidence":["a"],"behaviorModelVersion":"b1","carAudioRouteName":"car","connectedWiFiSSID":"wifi","courseAccuracyDegrees":10,"courseDegrees":90,"currentCadenceStepsPerSecond":1.75,"currentPaceSecondsPerMeter":0.75,"deviceMotion":{"attitudeRadians":{"x":0.5,"y":-0.25,"z":1},"gravity":{"x":0.5,"y":-0.25,"z":1},"headingDegrees":45,"magneticFieldAccuracy":2,"magneticFieldMicroteslas":{"x":0.5,"y":-0.25,"z":1},"rotationRate":{"x":0.5,"y":-0.25,"z":1},"userAcceleration":{"x":0.5,"y":-0.25,"z":1}},"deviceMotionSummary":{"meanRotationRateRadiansPerSecond":0.25,"meanUserAccelerationG":0.1,"peakRotationRateRadiansPerSecond":1,"peakUserAccelerationG":0.5,"rotationRateStandardDeviationRadiansPerSecond":0.125,"sampleCount":50,"userAccelerationStandardDeviationG":0.2},"floorsAscended":1,"floorsDescended":0,"frequentStops":true,"gpsAvailable":false,"id":"00000000-0000-0000-0000-000000000001","locationFixQuality":"precise","matchesPublicTransitRoute":true,"matchesRailRoute":true,"motion":"walking","motionConfidence":"high","nearAirport":true,"nearPort":true,"nearbyStation":true,"nearbyStationName":"강남","onWater":true,"point":{"altitude":12.5,"horizontalAccuracy":5,"latitude":37.5,"longitude":127.25,"verticalAccuracy":3},"powerState":"charging","pressureKilopascals":101.25,"relativeAltitudeMeters":2.5,"rideHailingHint":true,"screenBrightness":1,"screenIsOn":true,"sequence":7,"sourceDevice":"appleWatch","speedAccuracyMetersPerSecond":0.5,"speedMetersPerSecond":1.5,"stepCount":42,"subwayWiFiObservationStreak":0,"systemFloor":3,"timestamp":1762560000.25,"trackingKind":"running","trackingSessionEnded":false,"trackingSessionID":"00000000-0000-0000-0000-000000000003","trackingWasAutomaticallyDetected":true,"walkingRunningDistanceMeters":30.5,"watchAccelerationAverageG":{"x":0.5,"y":-0.25,"z":1},"watchAccelerationMeanJerkGPerSecond":0.5,"watchAccelerationStandardDeviationG":0.25,"watchWorkoutKind":"walk"}"#, expected: full)
        try Self.roundTrip(SensorReading.self, stored: #"{"frequentStops":false,"gpsAvailable":true,"id":"00000000-0000-0000-0000-000000000004","matchesPublicTransitRoute":false,"matchesRailRoute":false,"motion":"unknown","motionConfidence":"low","nearAirport":false,"nearPort":false,"nearbyStation":false,"onWater":false,"rideHailingHint":false,"timestamp":1762560000.25}"#, expected: minimal)

        let fullBytes = "VFNSMgAAAAAAAAAAAAAAAAAAAAEAACDAX1/HQQEAAAAAAMBCQAAAAAAA0F9AAAAAAAAAKUAAAAAAAAAUQAAAAAAAAAhAAQABAAAAAAAA+D8BAAAAAAAA4D8BAAAAAACAVkABAAAAAAAAJEABAgEAAAAAAAAEQAEAAAAAAFBZQAEAAAAAAAAAAAAAAAAAAAACAQEAAAAAAAAAAQAAAAAAAAAAASoAAAAAAAAAAQAAAAAAgD5AAQAAAAAAAOg/AQAAAAAAAPw/AZqZmZmZmek/AQAAAAAAAOA/AAAAAAAA0L8AAAAAAADwPwAAAAAAAOA/AAAAAAAA0L8AAAAAAADwPwAAAAAAAOA/AAAAAAAA0L8AAAAAAADwPwAAAAAAAOA/AAAAAAAA0L8AAAAAAADwPwEAAAAAAADgPwAAAAAAANC/AAAAAAAA8D8BAgAAAAAAAAABAAAAAACARkABMgAAAAAAAACamZmZmZm5P5qZmZmZmck/AAAAAAAA4D8AAAAAAADQPwAAAAAAAMA/AAAAAAAA8D8BAAAAAAAA4D8AAAAAAADQvwAAAAAAAPA/AQAAAAAAANA/AQAAAAAAAOA/AQMAAAAAAAAAAQIBAAAAAAAA8D8BAQABBAAAAHdpZmkBAAAAAAAAAAABAQYAAADqsJXrgqgBAQEBAQEBAQQAAAB3YWxrAQcAAAB3YWxraW5nAQAAAAAAAOw/AQEAAAABAAAAYQECAAAAYjEBAAAAAAAAAAAAAAAAAAAAAwECAQEBAQEHAAAAAAAAAAEAAQMAAABjYXI="
        let minimalBytes = "VFNSMgAAAAAAAAAAAAAAAAAAAAQAACDAX1/HQQAAAAAAAAUAAAAAAAAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=="
        #expect(try full.storageBytes().base64EncodedString() == fullBytes)
        #expect(try minimal.storageBytes().base64EncodedString() == minimalBytes)
        #expect(try SensorReading.fromStorageBytes(Data(base64Encoded: fullBytes)!) == full)
        #expect(try SensorReading.fromStorageBytes(Data(base64Encoded: minimalBytes)!) == minimal)
        // 초기화가 접은 값(밝기 1 상한, 음수 연속 횟수 0)이 저장값이다.
        #expect(full.screenBrightness == 1)
        #expect(full.subwayWiFiObservationStreak == 0)
    }
}
