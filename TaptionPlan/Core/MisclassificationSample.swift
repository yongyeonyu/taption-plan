import Foundation
import TaptionPlanCore

// 오분류 교정 표본(MSC1119A01). 사용자가 분류를 손으로 고쳤을 때 「자동 분류 → 사용자 분류」와 비식별 특징값만 한 건씩 남긴다.
// 이 형식에는 사람이 쓴 글도, 시간의 절대값도, 좌표도 없다. 저장 형식과 내보내는 형식을 같게 두어
// 「나가는 파일에만 실수로 날짜가 붙는」 일이 없게 한다. 이 파일은 순수 계산이라 SwiftUI·저장소 타입을 모른다.
//
// 나중에 서버로 보낼 때(이번엔 서버를 만들지 않는다): `exportData`가 만든 JSON을 그대로 `POST /classifier-samples` 본문으로 쓴다.
//   {"format":"bokki-misclassification","version":1,"ruleVersion":"classifier-v1r4","samples":[ … ]}

struct MisclassificationSample: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case activity, travel }

    /// 이 형식의 판. 특징 이름이 바뀌면 올린다(학습 자료와 어긋나므로).
    var schemaVersion = 1
    /// 기기에서 만든 무작위 값. 사람·기기를 가리키지 않는다.
    var id: UUID

    var kind: Kind
    /// 0…1439 — 그날 자정부터 분. 날짜는 넣지 않는다.
    var minuteOfDay: Int
    /// 0(일)…6(토).
    var weekdayIndex: Int
    /// 교정한 구간 길이(초).
    var durationSeconds: Int

    /// 자동 분류: 분류표 대분류 코드(예: work·movement·unconfirmed) 또는 `TravelMode` raw.
    var predicted: String
    /// 분류표에 있는 behavior 코드만. 없으면 nil.
    var predictedDetail: String?
    /// low·medium·high.
    var predictedConfidence: String?
    /// 0…1, 0.05 단위.
    var predictedScore: Double?

    /// 사용자 분류: 분류표 대분류 코드 또는 `TravelMode` raw. 사용자가 직접 만든 이름이면 "custom".
    var corrected: String
    var correctedDetail: String?
    /// 사용자가 직접 만든 이름이면 true — 이름 자체는 저장하지 않는다.
    var correctedIsCustom: Bool

    /// `ClassificationRules.version`. 어느 규칙이 만든 라벨인지 알고 학습에서 뺄 수 있게 남긴다.
    var ruleVersion: String
    var features: MisclassificationFeatures

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, kind, minuteOfDay, weekdayIndex, durationSeconds
        case predicted, predictedDetail, predictedConfidence, predictedScore
        case corrected, correctedDetail, correctedIsCustom, ruleVersion, features
    }

    /// 값이 없는 칸도 `null`로 적어 열쇠 집합이 언제나 같다(학습 자료의 열이 흔들리지 않게).
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion); try c.encode(id, forKey: .id); try c.encode(kind, forKey: .kind)
        try c.encode(minuteOfDay, forKey: .minuteOfDay); try c.encode(weekdayIndex, forKey: .weekdayIndex); try c.encode(durationSeconds, forKey: .durationSeconds)
        try c.encode(predicted, forKey: .predicted); try c.encode(predictedDetail, forKey: .predictedDetail)
        try c.encode(predictedConfidence, forKey: .predictedConfidence); try c.encode(predictedScore, forKey: .predictedScore)
        try c.encode(corrected, forKey: .corrected); try c.encode(correctedDetail, forKey: .correctedDetail)
        try c.encode(correctedIsCustom, forKey: .correctedIsCustom); try c.encode(ruleVersion, forKey: .ruleVersion); try c.encode(features, forKey: .features)
    }
}

struct MisclassificationFeatures: Codable, Equatable, Sendable {
    /// 0.5 단위.
    var averageSpeedKmh: Double?
    var maximumSpeedKmh: Double?
    /// 10m 단위.
    var distanceMeters: Double?
    var steps: Int?
    /// 1 단위.
    var stepCadencePerMinute: Double?
    /// 5m 단위(가로 정확도 중앙값).
    var gpsAccuracyMeters: Double?
    /// stationary·walking·running·cycling·automotive·unknown.
    var dominantMotion: String?
    /// 구간 표본 절반 이상이 Apple Watch 표본인가.
    var watchCovered: Bool
    /// 그 구간에서 읽은 원본 수. 0이면 특징값은 전부 nil이다.
    var sampleCount: Int

    static let none = MisclassificationFeatures(watchCovered: false, sampleCount: 0)

    private enum CodingKeys: String, CodingKey {
        case averageSpeedKmh, maximumSpeedKmh, distanceMeters, steps, stepCadencePerMinute, gpsAccuracyMeters, dominantMotion, watchCovered, sampleCount
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(averageSpeedKmh, forKey: .averageSpeedKmh); try c.encode(maximumSpeedKmh, forKey: .maximumSpeedKmh)
        try c.encode(distanceMeters, forKey: .distanceMeters); try c.encode(steps, forKey: .steps)
        try c.encode(stepCadencePerMinute, forKey: .stepCadencePerMinute); try c.encode(gpsAccuracyMeters, forKey: .gpsAccuracyMeters)
        try c.encode(dominantMotion, forKey: .dominantMotion); try c.encode(watchCovered, forKey: .watchCovered); try c.encode(sampleCount, forKey: .sampleCount)
    }
}

/// 특징 이름의 고정 순서. 이름을 바꾸면 `MisclassificationSample.schemaVersion`을 올린다.
enum MisclassificationFeatureSchema {
    static let sampleKeys = [
        "schemaVersion", "id", "kind", "minuteOfDay", "weekdayIndex", "durationSeconds",
        "predicted", "predictedDetail", "predictedConfidence", "predictedScore",
        "corrected", "correctedDetail", "correctedIsCustom", "ruleVersion", "features",
    ]
    static let featureNames = [
        "averageSpeedKmh", "maximumSpeedKmh", "distanceMeters", "steps", "stepCadencePerMinute",
        "gpsAccuracyMeters", "dominantMotion", "watchCovered", "sampleCount",
    ]
}

extension MisclassificationSample {
    static let exportFormat = "bokki-misclassification"
    static let exportVersion = 1

    /// 정말 분류가 바뀐 교정인가. 같은 분류를 다시 고른 경우는 표본이 아니다.
    static func isChange(
        predicted: String, predictedDetail: String?, corrected: String, correctedDetail: String?
    ) -> Bool {
        predicted != corrected || predictedDetail != correctedDetail
    }

    /// 표본 한 건을 만든다. `knownBehaviors`는 분류표에 있는 behavior 코드 집합(호출부가 분류표에서 준다).
    /// 원본이 0건이면 특징값은 전부 비운다 — 틀린 특징값을 지어내지 않는다.
    static func build(
        kind: Kind,
        span: TimeSpan,
        readings: [SensorReading],
        predicted: String,
        predictedDetail: String?,
        predictedConfidence: String?,
        predictedScore: Double?,
        corrected: String,
        correctedDetail: String?,
        correctedIsCustom: Bool,
        ruleVersion: String,
        calendar: Calendar,
        knownBehaviors: Set<String>,
        travelDistanceMeters: Double? = nil,
        id: UUID = UUID()
    ) -> MisclassificationSample {
        let start = span.start
        let minute = calendar.component(.hour, from: start) * 60 + calendar.component(.minute, from: start)
        let inside = readings.filter { $0.timestamp >= span.start && $0.timestamp <= span.end }
        return MisclassificationSample(
            id: id,
            kind: kind,
            minuteOfDay: min(1_439, max(0, minute)),
            weekdayIndex: min(6, max(0, calendar.component(.weekday, from: start) - 1)),
            durationSeconds: Int(span.duration.rounded()),
            predicted: predicted,
            predictedDetail: predictedDetail.flatMap { knownBehaviors.contains($0) ? $0 : nil },
            predictedConfidence: predictedConfidence.flatMap { ConfidenceLevel(rawValue: $0)?.rawValue },
            predictedScore: predictedScore.flatMap { $0.isFinite ? round($0, to: 0.05, clamp: 0...1) : nil },
            corrected: correctedIsCustom ? "custom" : corrected,
            correctedDetail: correctedIsCustom ? nil : correctedDetail.flatMap { knownBehaviors.contains($0) ? $0 : nil },
            correctedIsCustom: correctedIsCustom,
            ruleVersion: ruleVersion,
            features: features(readings: inside, span: span, travelDistanceMeters: travelDistanceMeters)
        )
    }

    static func features(readings: [SensorReading], span: TimeSpan, travelDistanceMeters: Double?) -> MisclassificationFeatures {
        guard !readings.isEmpty else { return .none }
        let speeds = readings.compactMap(\.speedMetersPerSecond).filter { $0 >= 0 && $0.isFinite }
        let cadences = readings.compactMap(\.currentCadenceStepsPerSecond).filter { $0 >= 0 && $0.isFinite }
        let accuracies = readings.compactMap { $0.point?.horizontalAccuracy }.filter { $0 >= 0 && $0.isFinite }.sorted()
        let watch = readings.filter { $0.sourceDevice == .appleWatch }.count
        let distance = travelDistanceMeters.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } ?? walkedDistance(readings)
        return MisclassificationFeatures(
            averageSpeedKmh: speeds.isEmpty ? nil : round(speeds.reduce(0, +) / Double(speeds.count) * 3.6, to: 0.5),
            maximumSpeedKmh: speeds.max().map { round($0 * 3.6, to: 0.5) },
            distanceMeters: distance.map { round($0, to: 10) },
            steps: ClassifierAdapter.stepCount(readings: readings, in: span),
            stepCadencePerMinute: cadences.isEmpty ? nil : round(cadences.reduce(0, +) / Double(cadences.count) * 60, to: 1),
            gpsAccuracyMeters: accuracies.isEmpty ? nil : round(accuracies[accuracies.count / 2], to: 5),
            dominantMotion: dominantMotion(readings),
            watchCovered: watch * 2 >= readings.count,
            sampleCount: readings.count
        )
    }

    /// `walkingRunningDistanceMeters`는 누적값이라 구간 안 증가분을 더한다. 줄면 측정이 다시 시작된 것으로 그 값을 새 거리로 본다.
    private static func walkedDistance(_ readings: [SensorReading]) -> Double? {
        let values = readings.sorted { $0.timestamp < $1.timestamp }.compactMap(\.walkingRunningDistanceMeters).filter { $0 >= 0 && $0.isFinite }
        guard values.count >= 2 else { return nil }
        var total = 0.0
        for (previous, next) in zip(values, values.dropFirst()) { total += next >= previous ? next - previous : next }
        return total > 0 ? total : nil
    }

    /// 최빈값. 동수면 더 조용한 쪽(stationary < walking < running < cycling < automotive < unknown)이 이긴다.
    private static func dominantMotion(_ readings: [SensorReading]) -> String? {
        let order: [MotionKind] = [.stationary, .walking, .running, .cycling, .automotive, .unknown]
        let counts = Dictionary(grouping: readings, by: \.motion).mapValues(\.count)
        return order.max { left, right in
            let l = counts[left] ?? 0, r = counts[right] ?? 0
            return l != r ? l < r : (order.firstIndex(of: left) ?? 0) > (order.firstIndex(of: right) ?? 0)
        }.flatMap { counts[$0] == nil ? nil : $0.rawValue }
    }

    private static func round(_ value: Double, to unit: Double, clamp range: ClosedRange<Double>? = nil) -> Double {
        let rounded = (value / unit).rounded() * unit
        return range.map { min($0.upperBound, max($0.lowerBound, rounded)) } ?? rounded
    }

    /// 내보내기·나중의 `POST /classifier-samples` 본문. 날짜·시각 문자열이 들어 있지 않다.
    static func exportData(_ samples: [MisclassificationSample], ruleVersion: String) -> Data {
        struct Payload: Encodable {
            var format = MisclassificationSample.exportFormat
            var version = MisclassificationSample.exportVersion
            var ruleVersion: String
            var samples: [MisclassificationSample]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(Payload(ruleVersion: ruleVersion, samples: samples))) ?? Data("{}".utf8)
    }
}
