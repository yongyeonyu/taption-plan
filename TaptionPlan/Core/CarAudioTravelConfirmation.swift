import Foundation

/// 차량 오디오(CarPlay·블루투스) 연결로 이동 구간의 수단을 자동차로 확정한다(CAR1029A01).
/// 연결 자체는 이동을 만들지 않고, 이미 있는 구간의 수단만 확정한다.
/// 경로 정보가 담긴 표본이 하나도 없으면(앱이 꺼져 있었음) 판정을 바꾸지 않는다.
enum CarAudioTravelConfirmation {
    /// 등록한 차: `TaptionActivityEngineAdapter.provenance(for:)`가 ground truth로 읽는 접두어.
    static let registeredEvidencePrefix = "사용자 확인 차량 블루투스"
    /// 미등록 기기: 구간 시작·끝과 연결·해제가 맞아떨어진 경우. UI는 이 근거로 등록을 권한다.
    static let matchedEvidencePrefix = "차량 오디오 연결·해제 일치"
    /// 구간 시작·끝에서 연결·해제를 인정하는 여유.
    static let edgeTolerance: TimeInterval = 10 * 60
    static let recentNameLimit = 10

    struct Result: Equatable, Sendable {
        var name: String
        var isRegistered: Bool

        var evidence: String {
            "\(isRegistered ? registeredEvidencePrefix : matchedEvidencePrefix) · \(name)"
        }
    }

    /// `readings`는 구간 안 표본, `context`는 구간 앞뒤 여유를 포함한 표본이다(겹쳐도 된다).
    static func evaluate(
        readings: [SensorReading],
        context: [SensorReading] = [],
        span: TimeSpan,
        registered: Set<String>
    ) -> Result? {
        var seen = Set<UUID>()
        let all = (readings + context)
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.timestamp < $1.timestamp }
        let inside = all.filter { span.contains($0.timestamp) }
        let worn = wornAudioNames(in: all).subtracting(registered)
        let names = inside.compactMap(\.carAudioRouteName).filter { !worn.contains($0) }
        guard !names.isEmpty else { return nil }
        if let name = names.first(where: registered.contains) {
            return Result(name: name, isRegistered: true)
        }
        guard let name = dominantName(names),
              connectsNearStart(name, inside: inside, span: span),
              disconnectsNearEnd(name, all: all, span: span) else { return nil }
        return Result(name: name, isRegistered: false)
    }

    /// 구간 기록 중 등록한 차에 연결된 몫이 이만큼이면 차를 탄 것이다.
    static let registeredConnectionShare = 0.5

    /// 등록한 차 연결은 수단 판정의 1순위 근거다. 다른 날 기억이나 잠긴 판정보다 앞선다.
    /// 사용자가 이 구간에 직접 고른 수단과 걷기·달리기(차에서 내려 걷는 중)만 건드리지 않는다(대표 지시, PAW1102A03).
    static func enforcingRegisteredCar(
        _ segments: [TravelSegment],
        readings: [SensorReading],
        registered: Set<String>,
        corrections: [TravelModeCorrection]
    ) -> [TravelSegment] {
        guard !registered.isEmpty else { return segments }
        return segments.map { segment in
            guard segment.mode != .car, segment.mode != .taxi,
                  segment.mode != .walking, segment.mode != .running else { return segment }
            // 탑승 확인 카드로 고른 수단("사용자 확인 · …")과 이 구간에 직접 고친 보정은 사용자의 결정이다.
            guard !segment.evidence.contains(where: { $0.hasPrefix("사용자 확인 ·") }),
                  !corrections.contains(where: { $0.span.overlapsMostly(segment.span) }) else { return segment }
            let inside = readings.filter { segment.span.contains($0.timestamp) }
            guard !inside.isEmpty else { return segment }
            let connected = inside.compactMap(\.carAudioRouteName).filter(registered.contains)
            guard Double(connected.count) / Double(inside.count) >= registeredConnectionShare,
                  let name = connected.first else { return segment }
            var value = segment
            value.mode = .car
            value.subwayRoute = nil
            value.confidence = .high
            value.isConfirmed = true
            value.evidence.removeAll { $0.hasPrefix("사용자 확인") }
            value.evidence.append(Result(name: name, isRegistered: true).evidence)
            return value
        }
    }

    /// 걸으면서 이만큼 연결돼 있던 기기는 차가 아니라 몸에 지닌 이어폰·넥밴드다(SUB1111A01).
    /// 수집은 블루투스 출력 전부를 차량 오디오 후보로 남기므로, 판정 쪽에서 걸은 시간으로 가른다.
    static let wornWhileWalking: TimeInterval = 3 * 60
    /// 걷기 표본 사이 간격이 이보다 길면 그 사이를 걸은 시간으로 치지 않는다.
    private static let wornSampleGap: TimeInterval = 60

    /// 걷거나 뛰는 표본에 붙어 `wornWhileWalking` 넘게 이어진 기기 이름.
    static func wornAudioNames(in readings: [SensorReading]) -> Set<String> {
        let ordered = readings.sorted { $0.timestamp < $1.timestamp }
        var walked: [String: TimeInterval] = [:]
        for (previous, next) in zip(ordered, ordered.dropFirst()) {
            guard let name = previous.carAudioRouteName, !name.isEmpty, next.carAudioRouteName == name,
                  previous.motion == .walking || previous.motion == .running,
                  next.motion == .walking || next.motion == .running else { continue }
            let gap = next.timestamp.timeIntervalSince(previous.timestamp)
            if gap > 0, gap <= wornSampleGap { walked[name, default: 0] += gap }
        }
        return Set(walked.filter { $0.value >= wornWhileWalking }.keys)
    }

    /// 몸에 지닌 오디오 기기 이름을 지운 표본. 등록한 차 이름은 그대로 둔다.
    static func withoutWornAudio(_ readings: [SensorReading], registered: Set<String> = []) -> [SensorReading] {
        let worn = wornAudioNames(in: readings).subtracting(registered)
        guard !worn.isEmpty else { return readings }
        return readings.map { reading in
            guard let name = reading.carAudioRouteName, worn.contains(name) else { return reading }
            var value = reading
            value.carAudioRouteName = nil
            return value
        }
    }

    /// 잠근 구간의 미등록 기기 확정을 새 판정이 다시 찾지 못했다. 이어폰을 차로 본 옛 판정이다(SUB1111A01).
    static func dropsStaleMatch(_ previous: TravelSegment, for candidate: TravelSegment) -> Bool {
        func matched(_ segment: TravelSegment) -> Bool { segment.evidence.contains { $0.hasPrefix(matchedEvidencePrefix) } }
        return matched(previous) && !matched(candidate)
    }

    static func confirms(_ evidence: [String]) -> Bool {
        evidence.contains {
            $0.hasPrefix(registeredEvidencePrefix) || $0.hasPrefix(matchedEvidencePrefix)
        }
    }

    /// 미등록 기기로 확정된 구간의 기기 이름을 최근 순으로 모은다. 기존 목록 뒤에 붙이고 10개까지 남긴다.
    static func recentNames(from travel: [TravelSegment], merging existing: [String]) -> [String] {
        let fresh = travel
            .sorted { $0.span.start > $1.span.start }
            .flatMap(\.evidence)
            .compactMap { matchedName(in: $0) }
        var result: [String] = []
        for name in fresh + existing where !result.contains(name) {
            result.append(name)
        }
        return Array(result.prefix(recentNameLimit))
    }

    static func matchedName(in evidence: String) -> String? {
        let prefix = matchedEvidencePrefix + " · "
        guard evidence.hasPrefix(prefix) else { return nil }
        let name = evidence.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    private static func dominantName(_ names: [String]) -> String? {
        let counts = names.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
        return counts.max { lhs, rhs in
            lhs.value != rhs.value ? lhs.value < rhs.value : lhs.key > rhs.key
        }?.key
    }

    /// 구간 시작 10분 안에 연결됐거나 시작부터 연결돼 있었다.
    private static func connectsNearStart(_ name: String, inside: [SensorReading], span: TimeSpan) -> Bool {
        guard let first = inside.first(where: { $0.carAudioRouteName == name }) else { return false }
        return first.timestamp.timeIntervalSince(span.start) <= edgeTolerance
    }

    /// 끝 10분 안까지 연결이 이어졌고, 끝 10분 안에 iPhone 표본이 해제를 실제로 봤다.
    /// 해제 표본이 없으면(끝난 뒤에도 계속 연결) 하루 종일 켜 둔 기기일 수 있어 확정하지 않는다.
    private static func disconnectsNearEnd(_ name: String, all: [SensorReading], span: TimeSpan) -> Bool {
        guard let lastOn = all.last(where: {
            $0.carAudioRouteName == name && $0.timestamp <= span.end.addingTimeInterval(edgeTolerance)
        }), span.end.timeIntervalSince(lastOn.timestamp) <= edgeTolerance else { return false }
        return all.contains {
            $0.timestamp > lastOn.timestamp
                && $0.timestamp <= span.end.addingTimeInterval(edgeTolerance)
                && $0.sourceDevice == .iPhone
                && $0.carAudioRouteName != name
        }
    }
}
