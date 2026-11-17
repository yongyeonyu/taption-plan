import Foundation

// 앱만 쓰는 위젯·라이브 액티비티 계산. 위젯 target은 이 파일을 컴파일하지 않는다(ARC1103A01 B안).

enum TaptionLiveActivityStickmanAnimation {
    static let frameCount = 24
    static let frameDuration: TimeInterval = 1.0 / 12.0
    static let phaseCount = frameCount

    static func frameIndex(
        at time: TimeInterval,
        isAnimating: Bool
    ) -> Int {
        guard isAnimating, time.isFinite else { return 0 }
        let tick = Int64(floor(time / frameDuration))
        let count = Int64(frameCount)
        return Int(((tick % count) + count) % count)
    }

    static func phase(at date: Date, reducesMotion: Bool = false) -> Int {
        frameIndex(
            at: date.timeIntervalSinceReferenceDate,
            isAnimating: !reducesMotion
        )
    }

    static func oscillation(for phase: Int) -> Double {
        sin(2 * .pi * Double(phase) / Double(phaseCount))
    }

    static func secondaryOscillation(for phase: Int) -> Double {
        sin(4 * .pi * Double(phase) / Double(phaseCount))
    }
}

enum TaptionWidgetSyncStatus: Equatable, Sendable {
    case synchronized(Date?)
    case pending
    case unavailable

    var displayName: String {
        switch self {
        case .synchronized(let generatedAt):
            guard let generatedAt else { return "동기화됨" }
            let minutes = max(0, Int(Date.now.timeIntervalSince(generatedAt) / 60))
            return minutes < 1 ? "동기화됨 · 방금" : "동기화됨 · \(minutes)분 전"
        case .pending: return "동기화 대기"
        case .unavailable: return "앱을 열어 동기화"
        }
    }

    static func compare(
        groundTruth: TaptionWidgetPayload,
        cached: TaptionWidgetPayload
    ) -> Self {
        guard let fingerprint = groundTruth.sourceFingerprint else {
            return .unavailable
        }
        guard cached.sourceFingerprint == fingerprint else {
            return .pending
        }
        if let groundTruthUpdatedAt = groundTruth.sourceSnapshotUpdatedAt,
           let cachedUpdatedAt = cached.sourceSnapshotUpdatedAt,
           cachedUpdatedAt < groundTruthUpdatedAt {
            return .pending
        }
        return .synchronized(cached.generatedAt)
    }
}
