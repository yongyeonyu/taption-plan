import Foundation

/// 신호 대기·엘리베이터처럼 3분 안 짧은 정지로 쪼개진 같은 자동 이동 구간을 하나로 잇는다 (CLN1110A01).
/// 표본 원본은 상태의 evidence에 그대로 남고, 합친 구간은 첫 조각의 식별자를 쓴다.
enum ActivityFragmentBridge {
    /// 3분: 신호 한 주기·엘리베이터 대기를 덮고, 기록으로 남기는 체류(5분)보다 짧다.
    static let maximumPause: TimeInterval = 3 * 60
    static let automaticSource = "activity-classifier-v1"
    static let evidenceLabel = "짧은 멈춤 합침"

    static func bridging(_ segments: [ActivitySegment]) -> [ActivitySegment] {
        var result: [ActivitySegment] = []
        var index = 0
        while index < segments.count {
            var current = segments[index]
            index += 1
            while isAutomatic(current), current.majorCategoryID == "movement" {
                let next = index < segments.count && isPause(segments[index]) ? index + 1 : index
                guard next < segments.count,
                      isAutomatic(segments[next]), segments[next].detailID == current.detailID,
                      segments[next].span.start.timeIntervalSince(current.span.end) < maximumPause else { break }
                current = joined(current, Array(segments[index...next]))
                index = next + 1
            }
            result.append(current)
        }
        return result
    }

    private static func isAutomatic(_ segment: ActivitySegment) -> Bool {
        !segment.isUserConfirmed && segment.provenance.source == automaticSource
    }

    static func isPause(_ segment: ActivitySegment) -> Bool {
        isAutomatic(segment) && segment.detailID == "activity.rest" && segment.span.duration < maximumPause
    }

    /// 이어 붙이기 전 상태의 끝이 `이동·짧은 정지`이고 정지 뒤에 새 구간이 생겼으면 앞 이동과 이어질 수 있다.
    /// 정지만 길어지는 동안에는 이어질 것이 없어 끝 구간만 고쳐도 전체 계산과 같다 (REV1110A06).
    static func mayBridge(before: ActivitySegment?, pause: ActivitySegment, tailCount: Int) -> Bool {
        guard tailCount > 1, isPause(pause), let before else { return false }
        return isAutomatic(before) && before.majorCategoryID == "movement"
    }

    private static func joined(_ head: ActivitySegment, _ rest: [ActivitySegment]) -> ActivitySegment {
        let span = ActivityTimeSpan(start: head.span.start, end: max(head.span.end, rest.map(\.span.end).max() ?? head.span.end))
        let moving = [head] + rest.filter { $0.detailID == head.detailID }
        let confidence = moving.map(\.confidence).min() ?? head.confidence
        let evidence = unique(moving.flatMap(\.evidence) + [evidenceLabel])
        return ActivitySegment(
            id: head.id, span: span, majorCategoryID: head.majorCategoryID, detailID: head.detailID,
            title: head.title, behavior: head.behavior, confidence: confidence, evidence: evidence,
            sampleCount: head.sampleCount + rest.reduce(0) { $0 + $1.sampleCount },
            isUserConfirmed: false,
            provenance: .init(
                tier: head.provenance.tier, status: head.provenance.status, source: head.provenance.source,
                evidence: unique(([head] + rest).flatMap(\.provenance.evidence) + [evidenceLabel]),
                confidence: confidence, span: span
            )
        )
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}
