import Foundation
import TaptionPlanCore

public struct FloorCalibrationPoint: Codable, Hashable, Sendable {
    public var floor: Int
    public var point: GeoPoint
    public var relativeAltitudeMeters: Double?
    public var pressureKilopascals: Double?
    public var altimeterSessionID: UUID?
    public var capturedAt: Date
    /// 사용자가 "지금 이 층"이라고 직접 확인한 기준점. 자동 추정은 이 기준을
    /// 덮거나 지우지 못한다. 그래야 사용자가 자기 데이터를 고칠 수 있다.
    public var isManual: Bool

    public init(
        floor: Int,
        point: GeoPoint,
        relativeAltitudeMeters: Double?,
        pressureKilopascals: Double?,
        altimeterSessionID: UUID?,
        capturedAt: Date,
        isManual: Bool = false
    ) {
        self.floor = floor
        self.point = point
        self.relativeAltitudeMeters = relativeAltitudeMeters
        self.pressureKilopascals = pressureKilopascals
        self.altimeterSessionID = altimeterSessionID
        self.capturedAt = capturedAt
        self.isManual = isManual
    }

    /// 이전 저장 파일에는 `isManual` 이 없다. 알 수 없는 출처는 자동으로 본다.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        floor = try values.decode(Int.self, forKey: .floor)
        point = try values.decode(GeoPoint.self, forKey: .point)
        relativeAltitudeMeters = try values.decodeIfPresent(
            Double.self,
            forKey: .relativeAltitudeMeters
        )
        pressureKilopascals = try values.decodeIfPresent(
            Double.self,
            forKey: .pressureKilopascals
        )
        altimeterSessionID = try values.decodeIfPresent(
            UUID.self,
            forKey: .altimeterSessionID
        )
        capturedAt = try values.decode(Date.self, forKey: .capturedAt)
        isManual = try values.decodeIfPresent(Bool.self, forKey: .isManual)
            ?? false
    }
}

/// 두 관측 사이의 고도 차이를 구하는 단 하나의 규칙. 같은 기압 세션의
/// 상대고도가 가장 정확하고, 기압차, GPS 고도 순으로 내려간다. 층 추정과 층
/// 높이 계산이 이 규칙을 함께 쓴다.
public enum AltitudeDelta {
    public enum Source: Sendable {
        case relativeAltitude
        case pressure
        case gps
    }

    public struct Sample: Sendable {
        public var altimeterSessionID: UUID?
        public var relativeAltitudeMeters: Double?
        public var pressureKilopascals: Double?
        public var altitudeMeters: Double?

        public init(_ reading: SensorReading) {
            altimeterSessionID = reading.altimeterSessionID
            relativeAltitudeMeters = reading.relativeAltitudeMeters
            pressureKilopascals = reading.pressureKilopascals
            altitudeMeters = reading.point?.altitude
        }

        public init(_ reference: FloorCalibrationPoint) {
            altimeterSessionID = reference.altimeterSessionID
            relativeAltitudeMeters = reference.relativeAltitudeMeters
            pressureKilopascals = reference.pressureKilopascals
            altitudeMeters = reference.point.altitude
        }

        /// 기록이 스스로 지닌 근거. GPS 고도는 기록에 남은 대표 좌표에서
        /// 가져온다.
        public init(_ evidence: FloorEvidence, altitudeMeters: Double?) {
            altimeterSessionID = evidence.altimeterSessionID
            relativeAltitudeMeters = evidence.relativeAltitudeMeters
            pressureKilopascals = evidence.pressureKilopascals
            self.altitudeMeters = altitudeMeters
        }
    }

    public static func between(
        _ baseline: Sample,
        and current: Sample
    ) -> (meters: Double, source: Source)? {
        // 상대고도의 0점은 기압 세션마다 새로 잡힌다. 세션을 모르는 표본끼리
        // (양쪽 다 nil) 비교하면 서로 다른 0점을 같은 기준으로 착각해 수십
        // 미터가 그대로 층수 오차가 된다. 그때는 절대 기압으로 내려간다.
        if let session = baseline.altimeterSessionID,
           session == current.altimeterSessionID,
           let start = baseline.relativeAltitudeMeters,
           let end = current.relativeAltitudeMeters {
            return (end - start, .relativeAltitude)
        }
        if let start = baseline.pressureKilopascals,
           let end = current.pressureKilopascals,
           start > 0,
           end > 0 {
            return (44_330 * (1 - pow(end / start, 0.1903)), .pressure)
        }
        if let start = baseline.altitudeMeters,
           let end = current.altitudeMeters {
            return (end - start, .gps)
        }
        return nil
    }
}

/// 기록에 남은 층수는 관측에서 파생된 값이다. 그 관측의 원본 표본은 7일 뒤
/// 지워지므로, 파생된 층수 옆에 근거가 된 숫자 몇 개를 함께 남긴다. 그래야
/// 기준점을 뒤늦게 고쳐도 보관 기간과 상관없이 다시 매길 수 있다.
///
/// 상대고도의 0점은 기압 세션마다 새로 잡힌다. 세션 식별자를 함께 남겨야
/// 다른 세션의 값을 같은 기준으로 착각해 빼는 일이 없다.
public struct FloorEvidence: Codable, Hashable, Sendable {
    public var measuredAt: Date
    public var relativeAltitudeMeters: Double?
    public var pressureKilopascals: Double?
    public var altimeterSessionID: UUID?
    /// 잰 자리에서 이 기록까지의 층수 차이. 한 체류가 층 이동으로 쪼개지면
    /// 뒤쪽 조각은 잰 자리보다 이만큼 위에 있다.
    public var floorOffset: Int

    public init(
        measuredAt: Date,
        relativeAltitudeMeters: Double? = nil,
        pressureKilopascals: Double? = nil,
        altimeterSessionID: UUID? = nil,
        floorOffset: Int = 0
    ) {
        self.measuredAt = measuredAt
        self.relativeAltitudeMeters = relativeAltitudeMeters
        self.pressureKilopascals = pressureKilopascals
        self.altimeterSessionID = altimeterSessionID
        self.floorOffset = floorOffset
    }

    /// 기압을 재지 못한 관측은 근거가 되지 못한다. 없는 근거를 남겨 두면
    /// 나중에 그 기록을 고칠 수 있다고 착각한다.
    public init?(_ reading: SensorReading) {
        guard reading.relativeAltitudeMeters != nil
                || reading.pressureKilopascals != nil else {
            return nil
        }
        self.init(
            measuredAt: reading.timestamp,
            relativeAltitudeMeters: reading.relativeAltitudeMeters,
            pressureKilopascals: reading.pressureKilopascals,
            altimeterSessionID: reading.altimeterSessionID
        )
    }

    public func offset(by floors: Int) -> FloorEvidence {
        var value = self
        value.floorOffset += floors
        return value
    }
}

/// 층 높이는 사용자가 맞추는 값이 아니다. "지금 몇 층인지"는 사람이 알고
/// 미터는 기기가 잰다. 서로 다른 층에서 받아 둔 기준점의 고도 차이를 층수로
/// 나눠 이 건물의 층 높이를 구한다. 기준이 한 층뿐이면 잴 것이 없으므로 nil을
/// 돌려주고 쓰던 값을 그대로 둔다.
public enum FloorHeightEstimator {
    public static let minimumMeters = 2.2
    public static let maximumMeters = 5.0

    public static func metersPerFloor(
        from references: [FloorCalibrationPoint]
    ) -> Double? {
        let sorted = newestPerFloor(references).sorted { $0.floor < $1.floor }
        var heights: [Double] = []
        for (index, base) in sorted.enumerated() {
            for target in sorted.dropFirst(index + 1) {
                let floors = target.floor - base.floor
                guard floors > 0,
                      let delta = AltitudeDelta.between(
                        AltitudeDelta.Sample(base),
                        and: AltitudeDelta.Sample(target)
                      ) else {
                    continue
                }
                // 위층은 아래층보다 높아야 한다. 부호가 뒤집힌 짝은 둘 중
                // 하나가 오염된 것이므로, abs로 부호를 감춰 멀쩡한 값처럼
                // 만들지 않는다.
                guard delta.meters > 0 else { continue }
                let height = delta.meters / Double(floors)
                // 범위를 벗어난 짝은 잘못 잰 것이다. 억지로 끌어다 맞추면
                // 멀쩡한 다른 기준까지 망가지므로 그냥 버린다.
                guard height >= minimumMeters, height <= maximumMeters else {
                    continue
                }
                heights.append(height)
            }
        }
        guard !heights.isEmpty else { return nil }
        return median(heights)
    }

    /// 같은 층 기준이 여러 개 남아 있으면 최근 것만 쓴다. 오래된 중복은 같은
    /// 층을 두 번 세어 중앙값을 한쪽으로 끌어당긴다.
    private static func newestPerFloor(
        _ references: [FloorCalibrationPoint]
    ) -> [FloorCalibrationPoint] {
        var newest: [Int: FloorCalibrationPoint] = [:]
        for reference in references {
            if let held = newest[reference.floor],
               held.capturedAt >= reference.capturedAt {
                continue
            }
            newest[reference.floor] = reference
        }
        return Array(newest.values)
    }

    public static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let ordered = values.sorted()
        let middle = ordered.count / 2
        return ordered.count.isMultiple(of: 2)
            ? (ordered[middle - 1] + ordered[middle]) / 2
            : ordered[middle]
    }
}

/// 기압계 한 표본은 흔들린다. 그 한 번을 영구 기준점으로 박으면 흔들림이
/// 이 건물의 모든 층 추정에 그대로 남는다. 그래서 수동 보정은 여러 표본을
/// 모아 하나로 줄인 뒤에만 기준을 남긴다.
public struct AltitudeBurstSample: Hashable, Sendable {
    public var relativeAltitudeMeters: Double?
    public var pressureKilopascals: Double?
    public var altimeterSessionID: UUID?
    public var timestamp: Date

    public init(
        relativeAltitudeMeters: Double? = nil,
        pressureKilopascals: Double? = nil,
        altimeterSessionID: UUID? = nil,
        timestamp: Date
    ) {
        self.relativeAltitudeMeters = relativeAltitudeMeters
        self.pressureKilopascals = pressureKilopascals
        self.altimeterSessionID = altimeterSessionID
        self.timestamp = timestamp
    }

    public var isUsable: Bool {
        relativeAltitudeMeters != nil || pressureKilopascals != nil
    }
}

/// 표본 묶음을 기준점 하나로 줄이는 규칙. CoreMotion을 모른다.
public enum AltitudeBurstReducer {
    /// 기압계 상대고도는 약 1초에 한 번 도착한다. 12개면 약 12초, 사용자가
    /// 가만히 서 있기를 요구할 수 있는 상한이다.
    public static let requestedSampleCount = 12
    /// 절반 넘게 모이면 중앙값이 흔들림을 이긴다. 그보다 적으면 버린다.
    public static let minimumSampleCount = 7
    /// 한 층은 최소 2.2m다. 그 절반보다 넉넉히 아래로 잡는다. 가만히 선
    /// 기기의 기압계 잡음은 수십 cm이므로, 이보다 벌어졌다면 사람이
    /// 움직였거나 센서를 믿을 수 없다는 뜻이다.
    public static let maximumSpreadMeters = 1.0

    public enum Outcome: Equatable, Sendable {
        case reduced(AltitudeBurstSample, spreadMeters: Double)
        case tooFewSamples(collected: Int)
        case tooNoisy(spreadMeters: Double)
    }

    /// 평균 대신 중앙값을 쓴다. 최대·최소를 버린 뒤 남는 표본이 열 개뿐이라
    /// 그 위에 다시 이상치 규칙을 얹으면 임계값 하나에 결과가 흔들린다.
    /// 중앙값은 조정할 값 없이 같은 강건함을 한 번에 얻는다. 버린 양끝은
    /// 값 대신 품질 판정에 쓴다.
    public static func reduce(_ samples: [AltitudeBurstSample]) -> Outcome {
        let ordered = samples.filter(\.isUsable).sorted {
            $0.timestamp < $1.timestamp
        }
        // 기압 세션이 중간에 끊기면 상대고도의 0점이 새로 잡힌다. 그 앞뒤를
        // 섞어 평균 내면 없던 층이 생긴다. 마지막 세션만 남긴다.
        let session = ordered.last?.altimeterSessionID
        let usable = ordered.filter { $0.altimeterSessionID == session }
        guard usable.count >= minimumSampleCount else {
            return .tooFewSamples(collected: usable.count)
        }
        let spread = trimmedSpreadMeters(usable)
        guard spread <= maximumSpreadMeters else {
            return .tooNoisy(spreadMeters: spread)
        }
        let reduced = AltitudeBurstSample(
            relativeAltitudeMeters: FloorHeightEstimator.median(
                usable.compactMap(\.relativeAltitudeMeters)
            ),
            pressureKilopascals: FloorHeightEstimator.median(
                usable.compactMap(\.pressureKilopascals)
            ),
            altimeterSessionID: session,
            timestamp: usable[usable.count / 2].timestamp
        )
        return .reduced(reduced, spreadMeters: spread)
    }

    /// 최대·최소 하나씩을 덜어 낸 뒤 남는 폭. 표본이 얼마나 서로 맞는지를
    /// 미터로 말한다.
    public static func trimmedSpreadMeters(_ samples: [AltitudeBurstSample]) -> Double {
        let ordered = metersSeries(samples).sorted()
        guard ordered.count > 2 else {
            return (ordered.last ?? 0) - (ordered.first ?? 0)
        }
        return ordered[ordered.count - 2] - ordered[1]
    }

    /// 상대고도가 있으면 그대로, 없으면 절대 기압을 미터로 바꿔 비교한다.
    private static func metersSeries(
        _ samples: [AltitudeBurstSample]
    ) -> [Double] {
        let relative = samples.compactMap(\.relativeAltitudeMeters)
        if relative.count >= minimumSampleCount { return relative }
        let pressures = samples.compactMap(\.pressureKilopascals).filter {
            $0 > 0
        }
        guard let reference = pressures.first else { return relative }
        return pressures.map {
            44_330 * (1 - pow($0 / reference, 0.1903))
        }
    }
}

extension SensorReading {
    /// 묶음에서 줄인 고도로 이 표본의 고도만 바꾼다. 위치는 그대로 두고
    /// 시각은 실제로 잰 때로 맞춘다.
    public func replacingAltitude(with sample: AltitudeBurstSample) -> SensorReading {
        var value = self
        value.relativeAltitudeMeters = sample.relativeAltitudeMeters
        value.pressureKilopascals = sample.pressureKilopascals
        value.altimeterSessionID = sample.altimeterSessionID
        value.timestamp = sample.timestamp
        return value
    }
}

/// 층 보정은 사용자가 실제로 고른 값에만 적용한다. 화면이 미리 채워 둔 값을
/// 그대로 확인해 버리면 고치려던 오차가 영구 기준으로 굳는다. 그래서 값을
/// 한 번 더 눌러 확인하기 전에는 보정이 잠겨 있다.
public struct FloorCalibrationPrompt: Equatable, Sendable {
    public static let range = -10...100

    public private(set) var floor: Int
    /// 사용자가 화면에 뜬 층수를 눈으로 확인하고 한 번 더 누른 상태.
    public private(set) var isArmed = false

    /// 미리 채우는 값은 이 장소에서 사용자가 마지막으로 확인한 층뿐이다.
    /// 앱이 추정한 층을 넣으면 고치려는 값이 곧 기본값이 된다.
    public init(lastConfirmedFloor: Int? = nil) {
        floor = Self.clamped(lastConfirmedFloor ?? 1)
    }

    public var canCommit: Bool { isArmed }

    public mutating func select(_ value: Int) {
        let next = Self.clamped(value)
        guard next != floor else { return }
        floor = next
        // 값이 바뀌면 확인은 무효다. 확인한 값과 보정할 값은 늘 같아야 한다.
        isArmed = false
    }

    public mutating func arm() { isArmed = true }

    public mutating func disarm() { isArmed = false }

    private static func clamped(_ value: Int) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

/// 보정 표본을 모으는 동안의 진행 상태. 다 모이기 전에는 아무것도 기록되지
/// 않는다.
public struct FloorCalibrationSampling: Equatable, Sendable {
    public var placeID: UUID
    public var floor: Int
    public var collected: Int
    public var target: Int

    public var progress: Double {
        guard target > 0 else { return 0 }
        return min(1, Double(collected) / Double(target))
    }

    public init(
        placeID: UUID,
        floor: Int,
        collected: Int,
        target: Int
    ) {
        self.placeID = placeID
        self.floor = floor
        self.collected = collected
        self.target = target
    }
}

public struct FloorCalibration: Codable, Hashable, Sendable {
    public var placeName: String
    public var referenceFloor: Int
    public var floorHeightMeters: Double
    public var referencePoint: GeoPoint?
    public var referenceRelativeAltitudeMeters: Double?
    public var referencePressureKilopascals: Double?
    public var referenceAltimeterSessionID: UUID?
    public var capturedAt: Date?
    public var referencePoints: [FloorCalibrationPoint]

    public static let homeTwentiethFloor = FloorCalibration(
        placeName: "집",
        referenceFloor: 20,
        floorHeightMeters: 3,
        referencePoint: nil,
        referenceRelativeAltitudeMeters: nil,
        referencePressureKilopascals: nil,
        referenceAltimeterSessionID: nil,
        capturedAt: nil,
        referencePoints: []
    )

    public init(
        placeName: String,
        referenceFloor: Int,
        floorHeightMeters: Double,
        referencePoint: GeoPoint?,
        referenceRelativeAltitudeMeters: Double?,
        referencePressureKilopascals: Double?,
        referenceAltimeterSessionID: UUID?,
        capturedAt: Date?,
        referencePoints: [FloorCalibrationPoint] = []
    ) {
        self.placeName = placeName
        self.referenceFloor = referenceFloor
        self.floorHeightMeters = floorHeightMeters
        self.referencePoint = referencePoint
        self.referenceRelativeAltitudeMeters = referenceRelativeAltitudeMeters
        self.referencePressureKilopascals = referencePressureKilopascals
        self.referenceAltimeterSessionID = referenceAltimeterSessionID
        self.capturedAt = capturedAt
        self.referencePoints = referencePoints
    }

    private enum CodingKeys: String, CodingKey {
        case placeName, referenceFloor, floorHeightMeters, referencePoint
        case referenceRelativeAltitudeMeters, referencePressureKilopascals
        case referenceAltimeterSessionID, capturedAt, referencePoints
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        placeName = try values.decode(String.self, forKey: .placeName)
        referenceFloor = try values.decode(Int.self, forKey: .referenceFloor)
        floorHeightMeters = try values.decodeIfPresent(
            Double.self,
            forKey: .floorHeightMeters
        ) ?? 3
        referencePoint = try values.decodeIfPresent(
            GeoPoint.self,
            forKey: .referencePoint
        )
        referenceRelativeAltitudeMeters = try values.decodeIfPresent(
            Double.self,
            forKey: .referenceRelativeAltitudeMeters
        )
        referencePressureKilopascals = try values.decodeIfPresent(
            Double.self,
            forKey: .referencePressureKilopascals
        )
        referenceAltimeterSessionID = try values.decodeIfPresent(
            UUID.self,
            forKey: .referenceAltimeterSessionID
        )
        capturedAt = try values.decodeIfPresent(Date.self, forKey: .capturedAt)
        referencePoints = try values.decodeIfPresent(
            [FloorCalibrationPoint].self,
            forKey: .referencePoints
        ) ?? []
    }

    public var isCaptured: Bool {
        (referencePoint != nil && capturedAt != nil) || !referencePoints.isEmpty
    }

    public var knownFloors: Set<Int> {
        Set([referenceFloor] + referencePoints.map(\.floor))
    }
}

/// 지하는 음수 층으로 저장하고 화면에는 "지하 N층"으로 적는다.
public enum FloorLabel {
    public static func korean(_ floor: Int) -> String {
        floor < 0 ? "지하 \(-floor)층" : "\(floor)층"
    }

    public static func english(_ floor: Int) -> String {
        floor < 0 ? "B\(-floor)Floor" : "\(floor)Floor"
    }
}

public struct CalibratedAltitudeEstimate: Codable, Hashable, Sendable {
    public var floor: Int
    public var seaLevelAltitudeMeters: Double
    public var verticalAccuracyMeters: Double
    public var confidence: ConfidenceLevel
    public var evidence: [String]

    public init(
        floor: Int,
        seaLevelAltitudeMeters: Double,
        verticalAccuracyMeters: Double,
        confidence: ConfidenceLevel,
        evidence: [String]
    ) {
        self.floor = floor
        self.seaLevelAltitudeMeters = seaLevelAltitudeMeters
        self.verticalAccuracyMeters = verticalAccuracyMeters
        self.confidence = confidence
        self.evidence = evidence
    }
}

/// 자동·수동 층수 보정이 적용될 때마다 남는 이력. 층별 기준점과 달리
/// 덮어쓰지 않고 시간순으로 쌓인다.
public struct FloorCalibrationEvent: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var placeID: UUID
    public var placeName: String
    public var floor: Int
    public var seaLevelAltitudeMeters: Double?
    public var isAutomatic: Bool
    public var capturedAt: Date

    public init(
        id: UUID = UUID(),
        placeID: UUID,
        placeName: String,
        floor: Int,
        seaLevelAltitudeMeters: Double? = nil,
        isAutomatic: Bool,
        capturedAt: Date
    ) {
        self.id = id
        self.placeID = placeID
        self.placeName = placeName
        self.floor = floor
        self.seaLevelAltitudeMeters = seaLevelAltitudeMeters
        self.isAutomatic = isAutomatic
        self.capturedAt = capturedAt
    }
}

public struct FloorTransition: Identifiable, Codable, Hashable, Sendable {
    /// 사용자가 직접 고른 도착 층. 자동 재계산은 이것을 덮지 않는다.
    public static let userConfirmedEvidence = "사용자 확인"

    public var id: UUID
    public var placeKey: String
    public var fromFloor: Int?
    public var toFloor: Int?
    public var relativeAltitudeMeters: Double
    public var span: TimeSpan
    public var confidence: ConfidenceLevel
    public var evidence: [String]
    /// `fromFloor` 를 만든 관측. 예전 빌드가 쓴 기록에는 없다.
    public var floorEvidence: FloorEvidence?

    public var isUserConfirmed: Bool {
        evidence.contains(Self.userConfirmedEvidence)
    }

    public init(
        id: UUID,
        placeKey: String,
        fromFloor: Int? = nil,
        toFloor: Int? = nil,
        relativeAltitudeMeters: Double,
        span: TimeSpan,
        confidence: ConfidenceLevel,
        evidence: [String],
        floorEvidence: FloorEvidence? = nil
    ) {
        self.id = id
        self.placeKey = placeKey
        self.fromFloor = fromFloor
        self.toFloor = toFloor
        self.relativeAltitudeMeters = relativeAltitudeMeters
        self.span = span
        self.confidence = confidence
        self.evidence = evidence
        self.floorEvidence = floorEvidence
    }
}
