import Foundation
import TaptionPlanEngine

extension TimeSpan {
    /// 짧은 쪽의 절반 이상이 겹치면 같은 구간으로 본다.
    func overlapsMostly(_ other: TimeSpan) -> Bool {
        guard let overlap = intersection(with: other) else { return false }
        return overlap.duration >= min(duration, other.duration) * 0.5
    }
}
