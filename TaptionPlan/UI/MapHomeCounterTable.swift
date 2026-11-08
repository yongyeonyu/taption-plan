import SwiftUI

/// 화랑이 머리 위에 세우는 카운터 창.
///
/// 연봉과 나머지 카운터를 **한 상자**에 담는다. 예전에는 연봉을 알약으로 따로 띄우고
/// 그 위에 표를 쌓아 두 덩어리로 보였는데, 연봉을 표의 마지막 줄(머리에 가장 가까운 줄)로
/// 넣어 창 하나로 만들었다.
///
/// 줄이 하나면 지금까지처럼 알약 하나로 두고, 둘부터는 한 상자 안에 줄을 붙여 세로로 길어지게 한다.
struct MapHomeCounterTable: View {
    /// 값이 같으면 다시 그리지 않는 층 아래에 있어, 글꼴을 고르면 바로 새로 그리게 직접 지켜본다.
    @AppStorage(TaptionFont.storageKey) private var fontSelection = TaptionFont.jua.rawValue
    /// 창의 맨 아래(머리에 가장 가까운) 줄에 놓는 연봉. 없으면 나머지 카운터만 담는다.
    let salary: MapHomeCounterSalary?
    /// 연봉 줄 바로 위에 놓는 용돈.
    var allowance: MapHomeCounterSalary? = nil
    let badges: [MapHomeCounterBadge]
    let language: MapHomeLanguage
    /// 재생 중에는 값이 0.25초마다 바뀌어 애니메이션이 끝나지 못하고 흔들린다.
    var isPlaying = false

    /// 두 줄 이상일 때 창의 폭. 값 자리수가 바뀌어도 창 폭이 흔들리지 않게 고정한다.
    static let boxWidth: CGFloat = 132
    /// 연봉 줄이 들어가면 값이 `1,234,567원`(영어 `$1,234,567.00`)까지 길어져 132pt에 들어가지 않는다.
    static let boxWidthWithSalary: CGFloat = 176

    private var moneyRows: [MapHomeCounterSalary] { [allowance, salary].compactMap { $0 } }
    private var rowCount: Int { badges.count + moneyRows.count }

    var body: some View {
        if rowCount == 1, let money = moneyRows.first {
            MapHomeCounterSalaryPill(salary: money, language: language, isPlaying: isPlaying)
        } else if rowCount == 1, let badge = badges.first {
            MapHomeCounterPill(kind: badge.kind, text: badge.text, language: language)
        } else if rowCount > 1 {
            VStack(spacing: 0) {
                ForEach(Array(badges.enumerated()), id: \.element.id) { index, badge in
                    if index > 0 { divider }
                    MapHomeCounterRow(kind: badge.kind, text: badge.text, language: language)
                }
                ForEach(Array(moneyRows.enumerated()), id: \.offset) { index, money in
                    if index > 0 || !badges.isEmpty { divider }
                    MapHomeCounterSalaryRow(salary: money, language: language)
                }
            }
            .frame(width: moneyRows.isEmpty ? Self.boxWidth : Self.boxWidthWithSalary)
            .mapHomeCounterPlate(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .animation(.snappy, value: rowCount)
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.tpLine.opacity(0.55))
            .frame(height: 1)
    }
}

/// 카운터 창에 박자를 주는 시계.
///
/// 예전에는 연봉 줄이 켜져 있을 때만 `TimelineView`가 돌았다. 연봉 카운터를 끄거나
/// 시급을 비우면 나머지 줄(걸음·거리·업무·학습·취미·운동)은 **다시 그려지지 않아**,
/// 업무 시간은 계속 흐르는데 화면 숫자는 멈춰 있었다(대표 지적: "카운터 위젯의 숫자는
/// 실시간으로 변경되어야 함", 2026-10-26). 이제 창 전체가 같은 시계를 쓰고, 지난 날처럼
/// 값이 변하지 않는 화면에서는 시계를 돌리지 않는다.
struct MapHomeCounterClock<Content: View>: View {
    /// 오늘을 보고 있거나 재생 중이면 값이 흐른다.
    let isLive: Bool
    let interval: TimeInterval
    private let content: (Date) -> Content

    @State private var anchor = Date()

    init(
        isLive: Bool,
        interval: TimeInterval = MapHomeCounterTimelinePolicy.refreshSeconds,
        @ViewBuilder content: @escaping (Date) -> Content
    ) {
        self.isLive = isLive
        self.interval = max(1, interval)
        self.content = content
    }

    var body: some View {
        if isLive {
            // 시작점을 붙들어 둔다. `.now`를 그때그때 넘기면 본문이 평가될 때마다
            // 일정이 새로 만들어져 박자가 처음으로 되감긴다.
            TimelineView(.periodic(from: anchor, by: interval)) { context in
                content(context.date)
            }
        } else {
            content(.now)
        }
    }
}

/// 창의 연봉 줄에 넘기는 값. 계산은 화면이 하고, 창은 글자만 받는다.
struct MapHomeCounterSalary: Equatable {
    let text: String
    /// 지금 근무 중이면 아이콘을 민트로 칠한다.
    let isWorking: Bool
    /// 근무와 상관없이 쌓이는 용돈 줄인지.
    var isAllowance = false
}

/// 창 안의 한 줄: 아이콘 · 이름 · 값(오른쪽 정렬). 값은 monospaced로 자리수가 변해도 흔들리지 않는다.
private struct MapHomeCounterRow: View {
    let kind: MapHomeCounterKind
    let text: String
    let language: MapHomeLanguage

    var body: some View {
        HStack(spacing: 6) {
            TaptionCuteIcon(kind.systemImage, size: 14)
                .foregroundStyle(Color.tpCounterIcon)
            Text(kind.badgeTitle(language))
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(10)), weight: .medium))
                .foregroundStyle(Color.tpSecondary)
                .lineLimit(1)
            Spacer(minLength: 6)
            Text(MapHomeCounterDigits.attributed(text, size: TaptionType.scaled(TaptionType.snapped(11)), weight: .bold))
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .bold))
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

    /// 카운터 창이 스스로 깨어나는 박자.
    ///
    /// 값이 분 단위라 분 경계만 넘기면 되지만, 걸음·거리는 센서가 들어오는 대로
    /// 바뀌어야 하고, 분 경계를 10초 늦게 잡으면 숫자도 그만큼 늦게 움직인다.
    /// 계산은 분 버킷으로 캐시하므로(`MapHomeCounterValueCache`) 10초마다 깨어나도
    /// 실제로 하루를 다시 세는 일은 1분에 한 번이다.
    static let refreshSeconds: TimeInterval = 10

    /// 재생 시각이나 사이드바 핸들 시각까지 자른다. 둘 다 없으면 nil(하루 전체 합계).
    static func cutoff(dayStart: Date, minute: Double?) -> Date? {
        guard let minute, minute.isFinite, minute >= 0 else { return nil }
        return dayStart.addingTimeInterval(min(minute, 24 * 60) * 60)
    }

    /// 걸음 수: 자른 시각까지 들어온 기기별 누적값을 구간 증가분으로 바꿔 워치 우선으로 더한다.
    static func stepCount(readings: [SensorReading], cutoff: Date?) -> Int? {
        let scoped = cutoff.map { limit in readings.filter { $0.timestamp <= limit } } ?? readings
        guard let first = scoped.map(\.timestamp).min(), let last = scoped.map(\.timestamp).max() else { return nil }
        return ClassifierAdapter.stepCount(readings: scoped, in: TimeSpan(start: first, end: last.addingTimeInterval(1)))
    }

    static func daySpan(of date: Date) -> TimeSpan {
        let calendar = MapHomeGrowthPolicy.localCalendar
        let start = calendar.startOfDay(for: date)
        return TimeSpan(start: start, end: calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400))
    }

    /// 이동 거리: 끝난 구간은 그대로, 지나가는 중인 구간은 지난 만큼만 센다.
    static func travelMeters(segments: [TravelSegment], cutoff: Date?, day: TimeSpan? = nil) -> Double {
        let visible = visibleSegments(segments, cutoff: cutoff, day: day)
        guard cutoff != nil else {
            return MapHomeDayTravelSummary.summed(visible).reduce(0) { $0 + $1.meters }
        }
        return visible.reduce(0) { $0 + $1.distanceMeters }
    }

    /// 보이는 시간만큼 거리를 나눈 구간들. 자정을 넘긴 구간은 이 날 몫만, 먼저 센 구간과 겹친 시간은 빼고 센다.
    static func visibleSegments(_ segments: [TravelSegment], cutoff: Date?, day: TimeSpan? = nil) -> [TravelSegment] {
        var countedUntil = Date.distantPast
        // 탑승 거리는 잘라 내기 전에 선로 길이로 바꾼다(SUB1108A01).
        return SubwayRideTrack.applyingTrackDistance(segments).sorted { $0.span.start < $1.span.start }.compactMap { segment in
            guard segment.distanceMeters.isFinite, segment.distanceMeters > 0 else { return nil }
            let start = max(segment.span.start, day?.start ?? .distantPast, countedUntil)
            let end = min(segment.span.end, day?.end ?? .distantFuture, cutoff ?? .distantFuture)
            guard start < end, segment.span.duration > 0 else { return nil }
            countedUntil = end
            var value = segment
            value.distanceMeters = segment.distanceMeters * min(1, end.timeIntervalSince(start) / segment.span.duration)
            value.span = TimeSpan(start: start, end: end)
            return value
        }
    }
}

/// 카운터 값을 분 버킷으로 캐시한다.
///
/// 재생 틱(30Hz)마다 하루치 phase를 다시 계산하면 프레임이 무너진다.
/// 표시 단위(1분)가 바뀔 때만 다시 계산하고 그 사이에는 같은 값을 돌려준다.
/// 멈춰 있을 때도 **지금 시각**을 버킷으로 쓴다 — 10초마다 깨어나는 시계가 매번
/// 하루 전체를 다시 세지 않게 하기 위해서다. 기록이 바뀌면(클립 편집·새 센서)
/// 버킷이 같아도 다시 센다.
@MainActor
final class MapHomeCounterValueCache {
    private var bucket: Int?
    private var revision: UInt64?
    private var cached: [String: TimeInterval] = [:]

    func categorySeconds(
        cutoff: Date?,
        now: Date,
        revision: UInt64,
        compute: (Date?) -> [String: TimeInterval]
    ) -> [String: TimeInterval] {
        let key = Int((cutoff ?? now).timeIntervalSince1970 / MapHomeCounterTimelinePolicy.bucketSeconds)
        if key == bucket, revision == self.revision { return cached }
        let value = compute(cutoff)
        bucket = key
        self.revision = revision
        cached = value
        return value
    }
}

/// 재생 중 카운터 값 계산을 1초에 몇 번으로 묶는다.
///
/// 오버레이는 재생 중 최대 60Hz로 다시 그려지고 카운터 창도 그때마다 값을 읽는다. 재생 시각은 0.25초에
/// 약 8분씩 넘어가 분 버킷 캐시가 매번 빗나가므로, 아이폰 11에서 이 계산만 재생 시간의 12%를 썼다
/// (125초 재생 중 15.3초, 호출당 2.9ms, PRF1030A01). 표시가 분 단위라 4Hz면 눈에 띄지 않는다.
/// 재생이 멈추면(`isPlaying == false`) 묶지 않고 바로 정확한 값을 계산한다.
@MainActor
final class MapHomeCounterBadgeThrottle {
    static let playbackInterval: TimeInterval = 0.25

    struct Key: Equatable {
        var revision: UInt64
        var day: Date
        var kinds: [MapHomeCounterKind]
        var english: Bool
        /// 멈춰 있을 때의 사이드바 핸들 분.
        var handleMinute: Int? = nil
    }

    private var lastKey: Key?
    private var lastAt: TimeInterval = -.infinity
    private var lastBadges: [MapHomeCounterBadge] = []

    func badges(
        key: Key,
        isPlaying: Bool,
        uptime: TimeInterval,
        compute: () -> [MapHomeCounterBadge]
    ) -> [MapHomeCounterBadge] {
        if isPlaying, key == lastKey, uptime - lastAt < Self.playbackInterval, uptime >= lastAt {
            return lastBadges
        }
        let value = compute()
        lastKey = key
        lastAt = uptime
        lastBadges = value
        return value
    }

    /// 재생 중이면 `playbackInterval` 단위 박자 번호, 아니면 nil.
    static func playbackTick(isPlaying: Bool, uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Int? {
        isPlaying ? Int(uptime / playbackInterval) : nil
    }
}

/// 재생 중에는 같은 박자 안에서 카운터 창 내용을 다시 만들지 않는 상자.
///
/// 재생 중 지도 위 표시층은 카메라를 따라 프레임마다 다시 그려지고, 그때마다 창 내용과 값 계산이 불렸다
/// (아이폰 11 Pro 13.5초 재생에 810회, PRF1101B01). 창 위치는 UIKit 뷰가 옮기므로 내용은 0.25초 박자면 된다.
/// 재생 중이 아니면(`playbackTick == nil`) 늘 다시 그린다.
struct MapHomeCounterContentGate<Content: View>: View, Equatable {
    let playbackTick: Int?
    var isCollapsed = false
    @ViewBuilder let content: () -> Content

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.isCollapsed == rhs.isCollapsed && lhs.playbackTick != nil && lhs.playbackTick == rhs.playbackTick
    }

    var body: some View { content() }
}

/// 카운터가 하나뿐일 때의 알약. 창으로 묶기 전과 같은 모양이다.
private struct MapHomeCounterPill: View {
    let kind: MapHomeCounterKind
    let text: String
    let language: MapHomeLanguage

    var body: some View {
        HStack(spacing: 4) {
            TaptionCuteIcon(kind.systemImage, size: 14)
                .foregroundStyle(Color.tpCounterIcon)
            Text(MapHomeCounterDigits.attributed(text, size: TaptionType.scaled(TaptionType.snapped(11)), weight: .bold))
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .bold))
                .monospacedDigit()
                .foregroundStyle(Color.tpInk)
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .mapHomeCounterPlate(in: Capsule())
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
            Image(systemName: salary.symbol(language: language))
                .font(.system(size: TaptionType.scaled(TaptionType.snapped(10)), weight: .semibold))
                .foregroundStyle(salary.isWorking ? Color.tpReferenceMint : Color.tpCounterIcon)
                .frame(width: 12)
            Text(salary.title(language: language))
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(10)), weight: .medium))
                .foregroundStyle(Color.tpSecondary)
                .lineLimit(1)
            Spacer(minLength: 6)
            Text(MapHomeCounterDigits.attributed(salary.text, size: TaptionType.scaled(TaptionType.snapped(11)), weight: .bold))
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .bold))
                .monospacedDigit()
                .foregroundStyle(Color.tpInk)
                .contentTransition(.numericText())
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(salary.title(language: language)) \(salary.text)")
    }
}

/// 연봉이 유일한 줄일 때의 알약. 창으로 묶기 전과 같은 모양이다.
private struct MapHomeCounterSalaryPill: View {
    let salary: MapHomeCounterSalary
    let language: MapHomeLanguage
    let isPlaying: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: salary.symbol(language: language))
                .foregroundStyle(salary.isWorking ? Color.tpReferenceMint : Color.tpSecondary)
            Text(MapHomeCounterDigits.attributed(salary.text, size: TaptionType.scaled(TaptionType.snapped(13)), weight: .bold))
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .bold))
        .foregroundStyle(Color.tpInk)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .mapHomeCounterPlate(in: Capsule())
        .animation(isPlaying ? nil : .snappy, value: salary.text)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(salary.title(language: language)) \(salary.text)")
    }
}

extension View {
    /// 카운터 창 바탕. 지도 위 유리는 밝은 지도 색이 비치면 밝은 글자가 묻혀, 테마 면 색을 깔아 읽히게 한다.
    func mapHomeCounterPlate<S: Shape>(in shape: S) -> some View {
        background(Color.tpSurface.opacity(0.92), in: shape)
    }
}

extension MapHomeCounterSalary {
    /// 통화에 맞는 아이콘. 기호가 없는 통화는 지폐로 둔다.
    static func symbol(language: MapHomeLanguage) -> String {
        switch AppRegion.current.currencyCode {
        case "KRW": "wonsign.circle.fill"
        case "USD", "CAD", "AUD", "MXN", "NZD", "SGD", "HKD", "TWD": "dollarsign.circle.fill"
        case "EUR": "eurosign.circle.fill"
        case "GBP": "sterlingsign.circle.fill"
        case "JPY", "CNY": "yensign.circle.fill"
        case "INR": "indianrupeesign.circle.fill"
        case "BRL": "brazilianrealsign.circle.fill"
        case "THB": "bahtsign.circle.fill"
        case "VND": "dongsign.circle.fill"
        case "IDR": "rupiahsign.circle.fill"
        case "CHF": "francsign.circle.fill"
        default: "banknote.fill"
        }
    }

    static let allowanceSymbol = "banknote.fill"

    func symbol(language: MapHomeLanguage) -> String {
        isAllowance ? Self.allowanceSymbol : Self.symbol(language: language)
    }

    func title(language: MapHomeLanguage) -> String {
        isAllowance ? language.text("용돈", "Allowance") : language.text("번 돈", "Earned")
    }

    /// 근무 시간과 시급으로 만든 번 돈 줄.
    static func earned(seconds: TimeInterval, hourlyRate: Double, isWorking: Bool, language: MapHomeLanguage) -> Self {
        Self(
            text: MapHomeSalaryPolicy.wonText(
                MapHomeSalaryPolicy.earnings(workSeconds: seconds, hourlyRate: hourlyRate), language: language
            ),
            isWorking: isWorking
        )
    }
}
