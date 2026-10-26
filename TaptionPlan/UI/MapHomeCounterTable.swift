import SwiftUI

/// 화랑이 머리 위에 세우는 카운터 창.
///
/// 연봉과 나머지 카운터를 **한 상자**에 담는다. 예전에는 연봉을 알약으로 따로 띄우고
/// 그 위에 표를 쌓아 두 덩어리로 보였는데, 연봉을 표의 마지막 줄(머리에 가장 가까운 줄)로
/// 넣어 창 하나로 만들었다.
///
/// 줄이 하나면 지금까지처럼 알약 하나로 두고, 둘부터는 한 상자 안에 줄을 붙여 세로로 길어지게 한다.
struct MapHomeCounterTable: View {
    /// 창의 맨 아래(머리에 가장 가까운) 줄에 놓는 연봉. 없으면 나머지 카운터만 담는다.
    let salary: MapHomeCounterSalary?
    let badges: [MapHomeCounterBadge]
    let language: MapHomeLanguage

    /// 두 줄 이상일 때 창의 폭. 값 자리수가 바뀌어도 창 폭이 흔들리지 않게 고정한다.
    static let boxWidth: CGFloat = 132
    /// 연봉 줄이 들어가면 값이 `1,234,567원`(영어 `1,234,567 USD`)까지 길어져 132pt에 들어가지 않는다.
    static let boxWidthWithSalary: CGFloat = 176

    private var rowCount: Int { badges.count + (salary == nil ? 0 : 1) }

    var body: some View {
        if rowCount == 1, let salary {
            MapHomeCounterSalaryPill(salary: salary, language: language)
        } else if rowCount == 1, let badge = badges.first {
            MapHomeCounterPill(kind: badge.kind, text: badge.text, language: language)
        } else if rowCount > 1 {
            VStack(spacing: 0) {
                ForEach(Array(badges.enumerated()), id: \.element.id) { index, badge in
                    if index > 0 { divider }
                    MapHomeCounterRow(kind: badge.kind, text: badge.text, language: language)
                }
                if let salary {
                    if !badges.isEmpty { divider }
                    MapHomeCounterSalaryRow(salary: salary, language: language)
                }
            }
            .frame(width: salary == nil ? Self.boxWidth : Self.boxWidthWithSalary)
            .mapHomeGlass(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .animation(.snappy, value: rowCount)
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.tpLine.opacity(0.55))
            .frame(height: 1)
    }
}

/// 창의 연봉 줄에 넘기는 값. 계산은 화면이 하고, 창은 글자만 받는다.
struct MapHomeCounterSalary: Equatable {
    let text: String
    /// 지금 근무 중이면 아이콘을 민트로 칠한다.
    let isWorking: Bool
}

/// 창 안의 한 줄: 아이콘 · 이름 · 값(오른쪽 정렬). 값은 monospaced로 자리수가 변해도 흔들리지 않는다.
private struct MapHomeCounterRow: View {
    let kind: MapHomeCounterKind
    let text: String
    let language: MapHomeLanguage

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: kind.systemImage)
                .font(.system(size: TaptionType.scaled(TaptionType.snapped(10)), weight: .semibold))
                .foregroundStyle(Color.tpAccent)
                .frame(width: 12)
            Text(kind.badgeTitle(language))
                .font(.system(size: TaptionType.scaled(TaptionType.snapped(10)), weight: .medium, design: .rounded))
                .foregroundStyle(Color.tpSecondary)
                .lineLimit(1)
            Spacer(minLength: 6)
            Text(text)
                .font(.system(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .bold, design: .rounded))
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
                .font(.system(size: TaptionType.scaled(TaptionType.snapped(10)), weight: .semibold))
                .foregroundStyle(Color.tpAccent)
            Text(text)
                .font(.system(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .bold, design: .rounded))
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

/// 창 안의 연봉 줄. 다른 줄과 같은 격자(아이콘 12 · 이름 · 값)를 써서 표로 읽힌다.
private struct MapHomeCounterSalaryRow: View {
    let salary: MapHomeCounterSalary
    let language: MapHomeLanguage

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: MapHomeCounterSalary.symbol(language: language))
                .font(.system(size: TaptionType.scaled(TaptionType.snapped(10)), weight: .semibold))
                .foregroundStyle(salary.isWorking ? Color.tpReferenceMint : Color.tpAccent)
                .frame(width: 12)
            Text(language.text("번 돈", "Earned"))
                .font(.system(size: TaptionType.scaled(TaptionType.snapped(10)), weight: .medium, design: .rounded))
                .foregroundStyle(Color.tpSecondary)
                .lineLimit(1)
            Spacer(minLength: 6)
            Text(salary.text)
                .font(.system(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Color.tpInk)
                .contentTransition(.numericText())
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(language.text("번 돈", "Earned")) \(salary.text)")
    }
}

/// 연봉이 유일한 줄일 때의 알약. 창으로 묶기 전과 같은 모양이다.
private struct MapHomeCounterSalaryPill: View {
    let salary: MapHomeCounterSalary
    let language: MapHomeLanguage

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: MapHomeCounterSalary.symbol(language: language))
                .foregroundStyle(salary.isWorking ? Color.tpReferenceMint : Color.tpSecondary)
            Text(salary.text)
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .font(.system(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .bold, design: .rounded))
        .foregroundStyle(Color.tpInk)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .mapHomeGlass(in: Capsule())
        .animation(.snappy, value: salary.text)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(language.text("번 돈", "Earned")) \(salary.text)")
    }
}

extension MapHomeCounterSalary {
    /// 통화에 맞는 아이콘. 영어 설정이면 달러, 아니면 원.
    static func symbol(language: MapHomeLanguage) -> String {
        language == .english ? "dollarsign.circle.fill" : "wonsign.circle.fill"
    }
}
