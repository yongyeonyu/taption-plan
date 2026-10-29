import Foundation
import TaptionPlanCore

// TSR2 is an explicit field-order contract. Change its version when changing the layout.
// TSR1 (before carAudioRouteName, CAR1029A01) is rejected: no production store ever wrote it
// (the SQLite store keeps readings as columns + `extra` JSON; this format is test-only).
// Portable JSON/Codable backups keep their independent model representation.
extension SensorReading: TaptionPlanBinaryRecord {
    private static let currentMagic: UInt32 = 0x32525354 // "TSR2"

    func storageBytes() throws -> Data {
        var writer = SensorRecordWriter()
        try writer.write(Self.currentMagic)
        try writeRecord(to: &writer)
        return writer.data
    }

    static func fromStorageBytes(_ data: Data) throws -> Self {
        try data.withUnsafeBytes { bytes in
            var reader = SensorRecordReader(bytes: bytes)
            guard try reader.read() as UInt32 == currentMagic else {
                throw TaptionPlanCanonicalStorageError.invalidPayload
            }
            let value = try readRecord(from: &reader)
            guard reader.remaining == 0 else { throw TaptionPlanCanonicalStorageError.invalidPayload }
            return value
        }
    }
}

private protocol SensorRecordValue {
    func writeRecord(to writer: inout SensorRecordWriter) throws
    static func readRecord(from reader: inout SensorRecordReader) throws -> Self
}

private struct SensorRecordWriter {
    var data = Data()

    init() { data.reserveCapacity(512) }

    mutating func write<Value: SensorRecordValue>(_ value: Value) throws {
        try value.writeRecord(to: &self)
    }

    mutating func integer<Value: FixedWidthInteger>(_ value: Value) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
}

private struct SensorRecordReader {
    let bytes: UnsafeRawBufferPointer
    var offset = 0
    var remaining: Int { bytes.count - offset }

    mutating func read<Value: SensorRecordValue>() throws -> Value {
        try Value.readRecord(from: &self)
    }

    mutating func integer<Value: FixedWidthInteger>(_ type: Value.Type) throws -> Value {
        guard remaining >= MemoryLayout<Value>.size else { throw TaptionPlanCanonicalStorageError.invalidPayload }
        let value = bytes.loadUnaligned(fromByteOffset: offset, as: Value.self)
        offset += MemoryLayout<Value>.size
        return Value(littleEndian: value)
    }
}

extension UInt32: SensorRecordValue {
    fileprivate func writeRecord(to writer: inout SensorRecordWriter) { writer.integer(self) }
    fileprivate static func readRecord(from reader: inout SensorRecordReader) throws -> Self { try reader.integer(Self.self) }
}

extension Int: SensorRecordValue {
    fileprivate func writeRecord(to writer: inout SensorRecordWriter) { writer.integer(Int64(self)) }
    fileprivate static func readRecord(from reader: inout SensorRecordReader) throws -> Self { Int(try reader.integer(Int64.self)) }
}

extension Double: SensorRecordValue {
    fileprivate func writeRecord(to writer: inout SensorRecordWriter) { writer.integer(bitPattern) }
    fileprivate static func readRecord(from reader: inout SensorRecordReader) throws -> Self {
        Double(bitPattern: try reader.integer(UInt64.self))
    }
}

extension Bool: SensorRecordValue {
    fileprivate func writeRecord(to writer: inout SensorRecordWriter) { writer.integer(UInt8(self ? 1 : 0)) }
    fileprivate static func readRecord(from reader: inout SensorRecordReader) throws -> Self {
        let value = try reader.integer(UInt8.self)
        guard value <= 1 else { throw TaptionPlanCanonicalStorageError.invalidPayload }
        return value == 1
    }
}

extension UUID: SensorRecordValue {
    fileprivate func writeRecord(to writer: inout SensorRecordWriter) {
        var value = uuid
        withUnsafeBytes(of: &value) { writer.data.append(contentsOf: $0) }
    }
    fileprivate static func readRecord(from reader: inout SensorRecordReader) throws -> Self {
        guard reader.remaining >= 16 else { throw TaptionPlanCanonicalStorageError.invalidPayload }
        let value = reader.bytes.loadUnaligned(fromByteOffset: reader.offset, as: uuid_t.self)
        reader.offset += 16
        return UUID(uuid: value)
    }
}

extension Date: SensorRecordValue {
    fileprivate func writeRecord(to writer: inout SensorRecordWriter) throws { try writer.write(timeIntervalSinceReferenceDate) }
    fileprivate static func readRecord(from reader: inout SensorRecordReader) throws -> Self {
        Date(timeIntervalSinceReferenceDate: try reader.read())
    }
}

extension String: SensorRecordValue {
    fileprivate func writeRecord(to writer: inout SensorRecordWriter) throws {
        guard let count = UInt32(exactly: utf8.count) else { throw TaptionPlanCanonicalStorageError.invalidPayload }
        writer.integer(count)
        writer.data.append(contentsOf: utf8)
    }
    fileprivate static func readRecord(from reader: inout SensorRecordReader) throws -> Self {
        let count = Int(try reader.integer(UInt32.self))
        guard count <= reader.remaining,
              let value = String(bytes: reader.bytes[reader.offset..<(reader.offset + count)], encoding: .utf8) else {
            throw TaptionPlanCanonicalStorageError.invalidPayload
        }
        reader.offset += count
        return value
    }
}

extension Optional: SensorRecordValue where Wrapped: SensorRecordValue {
    fileprivate func writeRecord(to writer: inout SensorRecordWriter) throws {
        try writer.write(self != nil)
        if let value = self { try writer.write(value) }
    }
    fileprivate static func readRecord(from reader: inout SensorRecordReader) throws -> Self {
        try reader.read() as Bool ? .some(try reader.read()) : nil
    }
}

extension Array: SensorRecordValue where Element == String {
    fileprivate func writeRecord(to writer: inout SensorRecordWriter) throws {
        guard let count = UInt32(exactly: count) else { throw TaptionPlanCanonicalStorageError.invalidPayload }
        writer.integer(count)
        for value in self { try writer.write(value) }
    }
    fileprivate static func readRecord(from reader: inout SensorRecordReader) throws -> Self {
        let count = Int(try reader.integer(UInt32.self))
        // Each string needs at least its four-byte length, even when empty.
        guard count <= reader.remaining / 4 else { throw TaptionPlanCanonicalStorageError.invalidPayload }
        var values: [String] = []
        values.reserveCapacity(count)
        for _ in 0..<count { values.append(try reader.read()) }
        return values
    }
}

private protocol SensorRecordEnum: SensorRecordValue, Equatable {
    static var storageCases: [Self] { get }
}

extension SensorRecordEnum {
    fileprivate func writeRecord(to writer: inout SensorRecordWriter) throws {
        guard let index = Self.storageCases.firstIndex(of: self), let value = UInt8(exactly: index) else {
            throw TaptionPlanCanonicalStorageError.invalidPayload
        }
        writer.integer(value)
    }
    fileprivate static func readRecord(from reader: inout SensorRecordReader) throws -> Self {
        let index = Int(try reader.integer(UInt8.self))
        guard storageCases.indices.contains(index) else { throw TaptionPlanCanonicalStorageError.invalidPayload }
        return storageCases[index]
    }
}

extension MotionKind: SensorRecordEnum {
    fileprivate static let storageCases: [Self] = [.stationary, .walking, .running, .cycling, .automotive, .unknown]
}

extension ConfidenceLevel: SensorRecordEnum {
    fileprivate static let storageCases: [Self] = [.low, .medium, .high]
}

extension TrackingKind: SensorRecordEnum {
    fileprivate static let storageCases: [Self] = [.automatic, .walking, .running]
}

extension TrackingDevice: SensorRecordEnum {
    fileprivate static let storageCases: [Self] = [.iPhone, .appleWatch]
}

extension DevicePowerState: SensorRecordEnum {
    fileprivate static let storageCases: [Self] = [.unknown, .unplugged, .charging, .full]
}

extension LocationFixQuality: SensorRecordEnum {
    fileprivate static let storageCases: [Self] = [.precise, .approximate]
}

extension SensorReading: SensorRecordValue {
    fileprivate func writeRecord(to writer: inout SensorRecordWriter) throws {
        try writer.write(id)
        try writer.write(timestamp)
        try writer.write(point)
        try writer.write(locationFixQuality)
        try writer.write(speedMetersPerSecond)
        try writer.write(speedAccuracyMetersPerSecond)
        try writer.write(courseDegrees)
        try writer.write(courseAccuracyDegrees)
        try writer.write(motion)
        try writer.write(motionConfidence)
        try writer.write(relativeAltitudeMeters)
        try writer.write(pressureKilopascals)
        try writer.write(altimeterSessionID)
        try writer.write(floorsAscended)
        try writer.write(floorsDescended)
        try writer.write(stepCount)
        try writer.write(walkingRunningDistanceMeters)
        try writer.write(currentPaceSecondsPerMeter)
        try writer.write(currentCadenceStepsPerSecond)
        try writer.write(averageActivePaceSecondsPerMeter)
        try writer.write(deviceMotion)
        try writer.write(deviceMotionSummary)
        try writer.write(watchAccelerationAverageG)
        try writer.write(watchAccelerationStandardDeviationG)
        try writer.write(watchAccelerationMeanJerkGPerSecond)
        try writer.write(systemFloor)
        try writer.write(powerState)
        try writer.write(screenBrightness)
        try writer.write(screenIsOn)
        try writer.write(gpsAvailable)
        try writer.write(connectedWiFiSSID)
        try writer.write(subwayWiFiObservationStreak)
        try writer.write(nearbyStation)
        try writer.write(nearbyStationName)
        try writer.write(matchesRailRoute)
        try writer.write(matchesPublicTransitRoute)
        try writer.write(frequentStops)
        try writer.write(rideHailingHint)
        try writer.write(nearAirport)
        try writer.write(nearPort)
        try writer.write(onWater)
        try writer.write(watchWorkoutKind)
        try writer.write(behavior)
        try writer.write(behaviorConfidenceScore)
        try writer.write(behaviorEvidence)
        try writer.write(behaviorModelVersion)
        try writer.write(trackingSessionID)
        try writer.write(trackingKind)
        try writer.write(trackingWasAutomaticallyDetected)
        try writer.write(sourceDevice)
        try writer.write(sequence)
        try writer.write(trackingSessionEnded)
        try writer.write(carAudioRouteName)
    }

    fileprivate static func readRecord(from reader: inout SensorRecordReader) throws -> Self {
        var value = try SensorReading(id: reader.read(), timestamp: reader.read())
        value.point = try reader.read()
        value.locationFixQuality = try reader.read()
        value.speedMetersPerSecond = try reader.read()
        value.speedAccuracyMetersPerSecond = try reader.read()
        value.courseDegrees = try reader.read()
        value.courseAccuracyDegrees = try reader.read()
        value.motion = try reader.read()
        value.motionConfidence = try reader.read()
        value.relativeAltitudeMeters = try reader.read()
        value.pressureKilopascals = try reader.read()
        value.altimeterSessionID = try reader.read()
        value.floorsAscended = try reader.read()
        value.floorsDescended = try reader.read()
        value.stepCount = try reader.read()
        value.walkingRunningDistanceMeters = try reader.read()
        value.currentPaceSecondsPerMeter = try reader.read()
        value.currentCadenceStepsPerSecond = try reader.read()
        value.averageActivePaceSecondsPerMeter = try reader.read()
        value.deviceMotion = try reader.read()
        value.deviceMotionSummary = try reader.read()
        value.watchAccelerationAverageG = try reader.read()
        value.watchAccelerationStandardDeviationG = try reader.read()
        value.watchAccelerationMeanJerkGPerSecond = try reader.read()
        value.systemFloor = try reader.read()
        value.powerState = try reader.read()
        value.screenBrightness = try reader.read()
        value.screenIsOn = try reader.read()
        value.gpsAvailable = try reader.read()
        value.connectedWiFiSSID = try reader.read()
        value.subwayWiFiObservationStreak = try reader.read()
        value.nearbyStation = try reader.read()
        value.nearbyStationName = try reader.read()
        value.matchesRailRoute = try reader.read()
        value.matchesPublicTransitRoute = try reader.read()
        value.frequentStops = try reader.read()
        value.rideHailingHint = try reader.read()
        value.nearAirport = try reader.read()
        value.nearPort = try reader.read()
        value.onWater = try reader.read()
        value.watchWorkoutKind = try reader.read()
        value.behavior = try reader.read()
        value.behaviorConfidenceScore = try reader.read()
        value.behaviorEvidence = try reader.read()
        value.behaviorModelVersion = try reader.read()
        value.trackingSessionID = try reader.read()
        value.trackingKind = try reader.read()
        value.trackingWasAutomaticallyDetected = try reader.read()
        value.sourceDevice = try reader.read()
        value.sequence = try reader.read()
        value.trackingSessionEnded = try reader.read()
        value.carAudioRouteName = try reader.read()
        return value
    }
}

extension GeoPoint: SensorRecordValue {
    fileprivate func writeRecord(to writer: inout SensorRecordWriter) throws {
        try writer.write(latitude)
        try writer.write(longitude)
        try writer.write(altitude)
        try writer.write(horizontalAccuracy)
        try writer.write(verticalAccuracy)
    }

    fileprivate static func readRecord(from reader: inout SensorRecordReader) throws -> Self {
        try Self(
            latitude: reader.read(),
            longitude: reader.read(),
            altitude: reader.read(),
            horizontalAccuracy: reader.read(),
            verticalAccuracy: reader.read()
        )
    }
}

extension SensorVector3: SensorRecordValue {
    fileprivate func writeRecord(to writer: inout SensorRecordWriter) throws {
        try writer.write(x)
        try writer.write(y)
        try writer.write(z)
    }

    fileprivate static func readRecord(from reader: inout SensorRecordReader) throws -> Self {
        try Self(
            x: reader.read(),
            y: reader.read(),
            z: reader.read()
        )
    }
}

extension DeviceMotionSnapshot: SensorRecordValue {
    fileprivate func writeRecord(to writer: inout SensorRecordWriter) throws {
        try writer.write(gravity)
        try writer.write(userAcceleration)
        try writer.write(rotationRate)
        try writer.write(attitudeRadians)
        try writer.write(magneticFieldMicroteslas)
        try writer.write(magneticFieldAccuracy)
        try writer.write(headingDegrees)
    }

    fileprivate static func readRecord(from reader: inout SensorRecordReader) throws -> Self {
        try Self(
            gravity: reader.read(),
            userAcceleration: reader.read(),
            rotationRate: reader.read(),
            attitudeRadians: reader.read(),
            magneticFieldMicroteslas: reader.read(),
            magneticFieldAccuracy: reader.read(),
            headingDegrees: reader.read()
        )
    }
}

extension DeviceMotionSummary: SensorRecordValue {
    fileprivate func writeRecord(to writer: inout SensorRecordWriter) throws {
        try writer.write(sampleCount)
        try writer.write(meanUserAccelerationG)
        try writer.write(userAccelerationStandardDeviationG)
        try writer.write(peakUserAccelerationG)
        try writer.write(meanRotationRateRadiansPerSecond)
        try writer.write(rotationRateStandardDeviationRadiansPerSecond)
        try writer.write(peakRotationRateRadiansPerSecond)
    }

    fileprivate static func readRecord(from reader: inout SensorRecordReader) throws -> Self {
        try Self(
            sampleCount: reader.read(),
            meanUserAccelerationG: reader.read(),
            userAccelerationStandardDeviationG: reader.read(),
            peakUserAccelerationG: reader.read(),
            meanRotationRateRadiansPerSecond: reader.read(),
            rotationRateStandardDeviationRadiansPerSecond: reader.read(),
            peakRotationRateRadiansPerSecond: reader.read()
        )
    }
}
