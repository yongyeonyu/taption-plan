import SwiftUI

/// 하루 눈금판의 각도·좌표·배치 수치. 화면 상태에 닿지 않고 계산만 한다.
/// 자정이 12시 방향이고 시계 방향으로 하루(0...1)가 흐른다.
enum ReviewClockGeometry {
    /// 시각 숫자가 캔버스 밖으로 잘리지 않도록 비워 두는 가장자리.
    static let outerMargin: CGFloat = 24

    static func outerRadius(side: CGFloat) -> CGFloat {
        side / 2 - outerMargin
    }

    static func angle(_ fraction: Double) -> Angle {
        .degrees(fraction * 360 - 90)
    }

    static func point(
        center: CGPoint,
        radius: CGFloat,
        angle: Angle
    ) -> CGPoint {
        CGPoint(
            x: center.x + radius * cos(angle.radians),
            y: center.y + radius * sin(angle.radians)
        )
    }

    /// 가운데에서 잰 거리(dx, dy)를 하루 비율로 바꾼다. 결과는 0..<1.
    static func clockFraction(dx: CGFloat, dy: CGFloat) -> Double {
        var fraction = (Angle(radians: atan2(dy, dx)).degrees + 90) / 360
        fraction -= floor(fraction)
        return fraction
    }

    /// 모서리 라벨에서 지시선이 닿는 점. 라벨 안쪽 가장자리의 세로 가운데다.
    static func cornerLabelAnchor(
        quadrant: CircularActivityLabelQuadrant,
        in size: CGSize,
        labelWidth: CGFloat,
        labelHeight: CGFloat
    ) -> CGPoint {
        let x = quadrant.isLeft
            ? 3 + labelWidth
            : size.width - 3 - labelWidth
        let y = quadrant.isTop
            ? 4 + labelHeight / 2
            : size.height - 4 - labelHeight / 2
        return CGPoint(x: x, y: y)
    }

    /// 직선 시간표에서 한 조각이 차지하는 막대. 아주 짧아도 1pt는 남긴다.
    static func linearBar(
        in rect: CGRect,
        startFraction: Double,
        endFraction: Double
    ) -> CGRect {
        let x = rect.minX + rect.width * startFraction
        let end = rect.minX + rect.width * endFraction
        return CGRect(
            x: x,
            y: rect.minY,
            width: max(1, end - x),
            height: rect.height
        )
    }

    /// 직선 시간표를 짚은 x를 하루 비율로 바꾼다. 끝점은 하루 안쪽에 둔다.
    static func linearFraction(
        x: CGFloat,
        timelineStart: CGFloat,
        timelineWidth: CGFloat
    ) -> Double {
        min(
            1 - 0.000_001,
            max(0, (x - timelineStart) / timelineWidth)
        )
    }

    /// 시각 숫자를 몇 시간마다 적을지. 좁을수록 성기게 적는다.
    static func hourLabelStride(width: CGFloat) -> Int {
        width < 560 ? 3 : (width < 900 ? 2 : 1)
    }

    /// 두 손가락 확대 배율. 1~4배 안에 묶는다.
    static func zoomScale(origin: CGFloat, factor: CGFloat) -> CGFloat {
        min(4, max(1, origin * max(0.01, factor)))
    }

    /// 접근성 조절로 자정을 넘으면 반대편으로 돌린다.
    static func wrappedFraction(_ value: Double) -> Double {
        var next = value
        if next < 0 { next += 1 }
        if next > 1 { next -= 1 }
        return next
    }
}

/// 눈금판 띠의 불투명도. 고른 것과 재생머리가 지나는 것만 살린다.
enum ReviewClockOpacity {
    static func activity(
        categoryID: String,
        highlight: ReviewClockHighlight?,
        isPlaybackActive: Bool,
        isUnderPlayhead: Bool
    ) -> Double {
        switch highlight {
        case .phase:
            return 0.1
        case .category(let selectedID):
            return categoryID == selectedID ? 1 : 0.1
        case .detail(let selection):
            return categoryID == activityCategoryID(for: selection.kind)
                ? 0.22
                : 0.08
        case nil:
            return !isPlaybackActive || isUnderPlayhead ? 1 : 0.4
        }
    }

    static func activityDetail(
        kind: RecordClockDetailKind,
        token: String,
        highlight: ReviewClockHighlight?
    ) -> Double {
        switch highlight {
        case .phase:
            return 0.1
        case .category(let selectedID):
            return activityCategoryID(for: kind) == selectedID ? 1 : 0.1
        case .detail(let selection):
            return selection.kind == kind && selection.token == token ? 1 : 0.1
        case nil:
            return 1
        }
    }

    static func phase(
        token: String,
        focusedToken: String?,
        highlight: ReviewClockHighlight?,
        isPlaying: Bool
    ) -> Double {
        switch highlight {
        case .phase(_, let selectedToken):
            return token == selectedToken ? 1 : 0.12
        case .category, .detail:
            return 0.12
        case nil:
            return isPlaying && token != focusedToken ? 0.3 : 1
        }
    }

    /// 상세 띠가 얹히는 활동 카테고리. 수면 단계는 수면, 이동수단은 이동 위다.
    static func activityCategoryID(
        for kind: RecordClockDetailKind?
    ) -> String? {
        switch kind {
        case .sleepStage: TimelineRowKind.sleep.rawValue
        case .travel: TimelineRowKind.movement.rawValue
        case .dayPhase, .weather, .location, nil: nil
        }
    }
}
