import Foundation
import TaptionPlanCore
import Testing
@testable import TaptionPlanStore

/// 앱 타깃에서 옮겨 온 저장소 actor·열 코덱이 패키지 안에서 같은 행을 쓰고 읽는지 본다.
/// 바이트 단위 형식 시험은 앱의 `TaptionStoreColumnCodingTests`·`TaptionStoreV2Tests`·`TaptionBackupV2Tests`가 그대로 맡는다.
struct TaptionStoreV2PackageTests {
    static let calendar = TaptionStoreV2.localGregorianCalendar()

    static func reading(_ index: Int) -> SensorReading {
        SensorReading(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!,
            timestamp: Date(timeIntervalSince1970: 1_762_560_000 + Double(index) * 60),
            point: GeoPoint(latitude: 37.5, longitude: 127.25, altitude: 12.5, horizontalAccuracy: 5, verticalAccuracy: 3),
            locationFixQuality: .precise, speedMetersPerSecond: 1.5, motion: .walking, motionConfidence: .high,
            stepCount: 42, deviceMotionSummary: DeviceMotionSummary(
                sampleCount: 50, meanUserAccelerationG: 0.1, userAccelerationStandardDeviationG: 0.2,
                peakUserAccelerationG: 0.5, meanRotationRateRadiansPerSecond: 0.25,
                rotationRateStandardDeviationRadiansPerSecond: 0.125, peakRotationRateRadiansPerSecond: 1
            ),
            screenIsOn: true, nearbyStationName: "강남", behavior: "walking", behaviorEvidence: ["a"],
            trackingKind: .walking, sourceDevice: .iPhone, sequence: index, carAudioRouteName: "car"
        )
    }

    @Test func columnCodecRoundTripsAReading() throws {
        let value = Self.reading(1)
        let row = try TaptionReadingRowCodec.row(for: value, calendar: Self.calendar)
        #expect(row.values.count == TaptionReadingRowCodec.columns.count)
        #expect(row.day == TaptionReadingRowCodec.dayNumber(for: value.timestamp, calendar: Self.calendar))
        #expect(try TaptionReadingRowCodec.reading(from: row) == value)
        #expect(TaptionReadingRowCodec.sameStoredContent(value, value))
    }

    @Test func storeWritesAndReadsReadings() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try TaptionStoreV2(url: folder.appendingPathComponent(TaptionStoreV2.fileName))
        let values = (1...3).map(Self.reading)
        _ = try await store.upsertReadings(values)
        #expect(try await store.readingCount() == 3)
        let loaded = try await store.readings(
            from: values[0].timestamp, to: values[2].timestamp.addingTimeInterval(1)
        )
        #expect(loaded == values)
        await store.close()
    }
}
