import SwiftUI

/// 화랑이 위에 쌓는 카운터 창.
///
/// 하나면 지금까지처럼 알약 하나로 두고, 둘부터는 **한 상자 안에 줄을 붙여** 세로로 길어지게 한다.
/// (예전에는 배지마다 캡슐을 따로 그려 `VStack`으로 띄웠기 때문에 창이 아니라 낱개 알약 더미로 보였다.)
struct MapHomeCounterTable: View {
    let badges: [MapHomeCounterBadge]
    let language: MapHomeLanguage

    /// 두 줄 이상일 때 창의 폭. 값 자리수가 바뀌어도 창 폭이 흔들리지 않게 고정한다.
    static let boxWidth: CGFloat = 132

    var body: some View {
        if badges.count == 1, let badge = badges.first {
            MapHomeCounterPill(kind: badge.kind, text: badge.text, language: language)
        } else if !badges.isEmpty {
            VStack(spacing: 0) {
                ForEach(Array(badges.enumerated()), id: \.element.id) { index, badge in
                    if index > 0 {
                        Rectangle()
                            .fill(Color.tpLine.opacity(0.55))
                            .frame(height: 1)
                    }
                    MapHomeCounterRow(kind: badge.kind, text: badge.text, language: language)
                }
            }
            .frame(width: Self.boxWidth)
            .mapHomeGlass(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .animation(.snappy, value: badges.count)
        }
    }
}

/// 창 안의 한 줄: 아이콘 · 이름 · 값(오른쪽 정렬). 값은 monospaced로 자리수가 변해도 흔들리지 않는다.
private struct MapHomeCounterRow: View {
    let kind: MapHomeCounterKind
    let text: String
    let language: MapHomeLanguage

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: kind.systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.tpAccent)
                .frame(width: 12)
            Text(kind.badgeTitle(language))
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(Color.tpSecondary)
                .lineLimit(1)
            Spacer(minLength: 6)
            Text(text)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Color.tpInk)
                .contentTransition(.numericText())
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(kind.badgeTitle(language)) \(text)")
    }
}

/// 카운터 값이 재생 시각을 따라 올라가게 하는 정책.
///
/// 하루 전체 합계만 읽으면 재생 중에도 숫자가 몇 번 튀고 마는데, 재생 중에는
/// **재생 시각까지로 잘라** 센다. 표시 단위가 분이라 1분 버킷으로 끊는다.
enum MapHomeCounterTimelinePolicy {
    /// 표시 단위. 카운터 글자가 분까지만 보여 주므로 1분이면 충분하다.
    static let bucketSeconds: TimeInterval = 60

    /// 재생 중일 때만 자를 시각을 준다(멈춰 있으면 하루 전체 합계).
    static func cutoff(dayStart: Date, minute: Double?, isRunning: Bool) -> Date? {
        guard isRunning, let minute, minute.isFinite, minute > 0 else { return nil }
        return dayStart.addingTimeInterval(min(minute, 24 * 60) * 60)
    }

    /// 걸음 수: 자른 시각까지 들어온 측정값 중 가장 큰 값(하루 누적값이다).
    static func stepCount(readings: [SensorReading], cutoff: Date?) -> Int? {
        let scoped = cutoff.map { limit in readings.filter { $0.timestamp <= limit } } ?? readings
        return scoped.compactMap(\.stepCount).filter { $0 > 0 }.max()
    }

    /// 이동 거리: 끝난 구간은 그대로, 지나가는 중인 구간은 지난 만큼만 센다.
    static func travelMeters(segments: [TravelSegment], cutoff: Date?) -> Double {
        guard let cutoff else {
            return MapHomeDayTravelSummary.entries(from: segments).reduce(0) { $0 + $1.meters }
        }
        return segments.reduce(0) { total, segment in
            guard segment.distanceMeters.isFinite, segment.distanceMeters > 0 else { return total }
            if segment.span.end <= cutoff { return total + segment.distanceMeters }
            guard segment.span.start < cutoff, segment.span.duration > 0 else { return total }
            let passed = cutoff.timeIntervalSince(segment.span.start) / segment.span.duration
            return total + segment.distanceMeters * min(1, max(0, passed))
        }
    }
}

/// 재생 틱(30Hz)마다 하루치 phase를 다시 계산하면 프레임이 무너진다.
/// 표시 단위(1분)가 바뀔 때만 다시 계산하고 그 사이에는 같은 값을 돌려준다.
@MainActor
final class MapHomeCounterValueCache {
    private var bucket: Int?
    private var cached: [String: TimeInterval] = [:]

    func categorySeconds(
        cutoff: Date?,
        compute: (Date) -> [String: TimeInterval]
    ) -> [String: TimeInterval] {
        guard let cutoff else {
            // 멈춰 있으면 하루 전체 합계다. 기록이 늘어날 수 있으니 캐시하지 않는다.
            bucket = nil
            return compute(.now)
        }
        let key = Int(cutoff.timeIntervalSince1970 / MapHomeCounterTimelinePolicy.bucketSeconds)
        if key == bucket { return cached }
        let value = compute(cutoff)
        bucket = key
        cached = value
        return value
    }
}

/// 카운터가 하나뿐일 때의 알약. 창으로 묶기 전과 같은 모양이다.
private struct MapHomeCounterPill: View {
    let kind: MapHomeCounterKind
    let text: String
    let language: MapHomeLanguage

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: kind.systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.tpAccent)
            Text(text)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Color.tpInk)
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .mapHomeGlass(in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(kind.badgeTitle(language)) \(text)")
    }
}
