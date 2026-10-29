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
        let names = inside.compactMap(\.carAudioRouteName)
        guard !names.isEmpty else { return nil }
        if let name = names.first(where: registered.contains) {
            return Result(name: name, isRegistered: true)
        }
        guard let name = dominantName(names),
              connectsNearStart(name, inside: inside, span: span),
              disconnectsNearEnd(name, all: all, span: span) else { return nil }
        return Result(name: name, isRegistered: false)
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
