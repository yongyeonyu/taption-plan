import Foundation
import TaptionPlanEngine

struct RecordClockArc: Identifiable, Equatable, Sendable {
    let id: String
    let categoryID: String
    /// 하루를 0…1로 본 시작·끝 위치. 자정이 0이다.
    let startFraction: Double
    let endFraction: Double
}

struct RecordClockRing: Identifiable, Equatable, Sendable {
    let id: String
    let categoryID: String
    let duration: TimeInterval
    let arcs: [RecordClockArc]
}

/// 하루 눈금판에 덧대는 띠. 카테고리 고리가 "무엇을 했는가"라면, 그 바깥의
/// `dayPhase` 는 "어떤 하루였는가"이고 안쪽 띠들은 그 안의 결이다. 한 띠에는
/// 종류가 다른 조각이 이어 붙는다.
enum RecordClockDetailKind: String, Equatable, Sendable {
    case dayPhase
    case sleepStage
    case travel
    case weather
    case location
}

struct RecordClockDetailArc: Identifiable, Equatable, Sendable {
    let id: String
    /// 색과 이름을 고르는 열쇠. 수면은 `SleepStage`, 이동은 `TravelMode`의
    /// 원시값이다.
    let token: String
    let startFraction: Double
    let endFraction: Double
}

struct RecordClockDetailRing: Identifiable, Equatable, Sendable {
    let id: String
    let kind: RecordClockDetailKind
    let arcs: [RecordClockDetailArc]
}

/// 원형 시간표의 날씨 조각은 한 칸에 온도·상태·미세먼지를 함께 보인다.
/// 문자열 하나로 보관해 기존의 가벼운 링 모델과 범례 선택을 그대로 쓴다.
enum WeatherClockToken {
    static func make(_ context: WeatherContext) -> String {
        let condition = context.condition.replacingOccurrences(of: "|", with: "/")
        let symbol = context.symbolName.replacingOccurrences(of: "|", with: "/")
        let temperature = Int(context.temperatureCelsius.rounded())
        let air = context.airQuality
        let grade = air.map { String($0.overallGrade.rawValue) } ?? "-"
        let pm10 = air.map { String(Int($0.pm10MicrogramsPerCubicMeter.rounded())) } ?? "-"
        let pm25 = air.map { String(Int($0.pm25MicrogramsPerCubicMeter.rounded())) } ?? "-"
        return [condition, symbol, String(temperature), grade, pm10, pm25].joined(separator: "|")
    }

    static func displayName(_ token: String) -> String {
        let parts = token.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 6, let temperature = Int(parts[2]) else { return token }
        return "\(weatherEmoji(for: parts[1])) \(temperature)° · \(airEmoji(for: parts[3]))"
    }

    /// 원형 시간표의 호출 라벨에서 미세먼지 표식을 더 작게 그릴 수 있도록
    /// 저장된 토큰을 세 조각으로 나눈다. 저장 형식은 바꾸지 않는다.
    static func compactParts(
        _ token: String
    ) -> (weather: String, temperature: String, air: String)? {
        let parts = token.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 6, let temperature = Int(parts[2]) else { return nil }
        return (
            weatherEmoji(for: parts[1]),
            String(temperature),
            airEmoji(for: parts[3])
        )
    }

    static func airGrade(_ token: String) -> AirQualityGrade? {
        let parts = token.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 6, let raw = Int(parts[3]) else { return nil }
        return AirQualityGrade(rawValue: raw)
    }

    private static func weatherEmoji(for symbol: String) -> String {
        switch symbol {
        case "sun.max.fill", "sun.min.fill": "☀️"
        case "moon.fill", "moon.stars.fill": "🌙"
        case "cloud.sun.fill", "cloud.moon.fill": "🌤️"
        case "cloud.fill": "☁️"
        case "cloud.fog.fill": "🌫️"
        case "cloud.drizzle.fill": "🌦️"
        case "cloud.sleet.fill": "🌨️"
        case "cloud.rain.fill", "cloud.heavyrain.fill": "🌧️"
        case "cloud.snow.fill": "❄️"
        case "cloud.bolt.rain.fill": "⛈️"
        default: "🌡️"
        }
    }

    private static func airEmoji(for rawGrade: String) -> String {
        switch Int(rawGrade).flatMap(AirQualityGrade.init(rawValue:)) {
        case .good: "🟢"
        case .moderate: "🟡"
        case .bad: "🟠"
        case .veryBad: "🔴"
        case nil: "⚪️"
        }
    }
}

/// 눈금판에 덧대는 띠의 조각을 만든다. 이미 받아 둔 수면 단계와 이동 구간,
/// 정지 문맥만 읽고 건강 데이터를 새로 묻지 않는다.
enum RecordClockDetailEngine {
    /// 이보다 짧은 조각은 띠 굵기보다 얇게 그려져 보이지도 않으면서 그리는
    /// 값만 늘린다. 하루의 0.4%는 약 6분이다.
    static let minimumArcFraction: Double = 0.004

    /// 한 띠가 가질 수 있는 조각 수의 상한. 넘으면 기준을 넓혀 더 합친다.
    /// 재생 중에는 이 띠를 프레임마다 다시 그리므로 상한이 곧 예산이다.
    static let maximumArcCount = 32

    /// 가장 바깥의 일과 띠. 조각을 만드는 규칙은 `DayPhaseEngine` 이 정하고,
    /// 여기서는 안쪽 띠와 똑같은 기준으로 얇은 조각을 합쳐 그릴 값을 줄인다.
    static func phaseRing(
        actuals: [ActualRecord],
        travel: [TravelSegment],
        stays: [PlaceStay],
        placeKinds: [String: FrequentPlaceKind],
        in span: TimeSpan,
        asOf: Date = .now,
        scope: RecordAnalysisScope = .legacy
    ) -> RecordClockDetailRing? {
        let phases = DayPhaseEngine.completePhases(
            actuals: actuals,
            travel: travel,
            stays: stays,
            placeKinds: placeKinds,
            in: span,
            asOf: asOf
        )
        let pieces = phases.map { phase -> (String, TimeSpan) in
            (scope.phase(phase.phase).rawValue, phase.span)
        }
        return ring(
            kind: .dayPhase,
            pieces: pieces,
            in: span
        )
    }

    /// 두 번째이자 마지막 단계인 활동 띠에 덮어 쓸 세부 근거. 수면 단계와
    /// 이동수단은 별도 상세 띠를 만들지 않고 해당 활동 구간의 색을 바꾼다.
    static func activityRings(
        sleepSessions: [SleepSession],
        travel: [TravelSegment],
        in span: TimeSpan,
        scope: RecordAnalysisScope = .legacy
    ) -> [RecordClockDetailRing] {
        [
            activitySleepRing(
                sessions: sleepSessions,
                in: span,
                scope: scope
            ),
            travelRing(
                segments: travel,
                in: span,
                scope: scope
            ),
        ].compactMap { $0 }
    }

    /// 수면 단계 띠. HealthKit은 같은 시각에 여러 단계를 겹쳐 보내므로
    /// 경계마다 한 단계를 골라 한 줄로 편다.
    static func sleepRing(
        sessions: [SleepSession],
        in span: TimeSpan,
        scope: RecordAnalysisScope = .legacy
    ) -> RecordClockDetailRing? {
        var seen = Set<UUID>()
        var clipped: [(stage: SleepStage, span: TimeSpan)] = []
        for session in sessions {
            for segment in session.segments {
                guard seen.insert(segment.id).inserted else { continue }
                let stage: SleepStage?
                switch scope {
                case .legacy:
                    stage = segment.stage
                case .canonical:
                    stage = RecordAnalysisCategoryPolicy.canonicalSleepStage(
                        segment.stage
                    )
                }
                guard let stage else { continue }
                guard let visible = segment.span.intersection(with: span),
                      visible.duration > 0 else {
                    continue
                }
                clipped.append((stage, visible))
            }
        }
        return ring(
            kind: .sleepStage,
            pieces: resolvedStages(clipped),
            in: span
        )
    }

    /// 활동 띠에는 실제로 잠든 단계만 올린다. `침대에 있음`과 `깨어 있음`은
    /// 수면 단계가 아니므로 기존 수면 구간의 바탕색으로 남는다.
    static func activitySleepRing(
        sessions: [SleepSession],
        in span: TimeSpan,
        scope: RecordAnalysisScope = .legacy
    ) -> RecordClockDetailRing? {
        guard let source = sleepRing(
            sessions: sessions,
            in: span,
            scope: scope
        ) else {
            return nil
        }
        let asleep = source.arcs.filter {
            SleepStage(rawValue: $0.token)?.isAsleep == true
        }
        guard !asleep.isEmpty else { return nil }
        let hasWatchSource = sessions.flatMap(\.segments).contains { segment in
            segment.sourceName.localizedCaseInsensitiveContains("watch")
                || segment.deviceName?
                    .localizedCaseInsensitiveContains("watch") == true
        }
        guard !hasWatchSource else {
            return RecordClockDetailRing(
                id: source.id,
                kind: source.kind,
                arcs: asleep
            )
        }
        let pieces = asleep.map { arc in
            (
                SleepStage.asleepUnspecified.rawValue,
                TimeSpan(
                    start: span.start.addingTimeInterval(
                        span.duration * arc.startFraction
                    ),
                    end: span.start.addingTimeInterval(
                        span.duration * arc.endFraction
                    )
                )
            )
        }
        return ring(kind: .sleepStage, pieces: pieces, in: span)
    }

    /// 이동 구간 띠. 같은 이동 수단이 이어지면 한 조각으로 붙인다.
    static func travelRing(
        segments: [TravelSegment],
        in span: TimeSpan,
        scope: RecordAnalysisScope = .legacy
    ) -> RecordClockDetailRing? {
        var seen = Set<UUID>()
        var pieces: [(token: String, span: TimeSpan)] = []
        for segment in segments.sorted(by: { $0.span.start < $1.span.start }) {
            guard seen.insert(segment.id).inserted else { continue }
            guard let visible = segment.span.intersection(with: span),
                  visible.duration > 0 else {
                continue
            }
            // 겹쳐 들어온 구간도 한 줄에 그려야 하므로 앞 조각 뒤로 민다.
            let start = max(visible.start, pieces.last?.span.end ?? visible.start)
            guard start < visible.end else { continue }
            let token: String
            switch scope {
            case .legacy:
                token = segment.mode.rawValue
            case .canonical:
                token = RecordAnalysisCategoryPolicy.movementToken(
                    for: segment.mode
                )
            }
            pieces.append(
                (
                    token,
                    TimeSpan(start: start, end: visible.end)
                )
            )
        }
        return ring(kind: .travel, pieces: pieces, in: span)
    }

    /// 측정 시각별 날씨 띠. 같은 상태는 `WeatherTimelineEngine`이 하나로
    /// 합치고, 상태가 바뀐 시각만 원 안쪽에서 경계를 만든다.
    static func weatherRing(
        contexts: [WeatherContext],
        in span: TimeSpan,
        asOf: Date = .now
    ) -> RecordClockDetailRing? {
        let limit = min(span.end, asOf)
        guard span.start < limit else { return nil }
        let visibleSpan = TimeSpan(start: span.start, end: limit)
        let pieces = WeatherTimelineEngine.coalesced(contexts).compactMap {
            context -> (token: String, span: TimeSpan)? in
            guard context.observedAt < limit,
                  let visible = WeatherTimelineEngine.span(for: context)
                    .intersection(with: visibleSpan),
                  visible.duration > 0 else { return nil }
            return (WeatherClockToken.make(context), visible)
        }
        return ring(kind: .weather, pieces: pieces, in: span)
    }

    /// 머문 장소 띠. 날씨와 함께 상세 고리 아래의 환경 정보로 보여 준다.
    /// 장소 이름과 층수만 토큰으로 보관하고, 원본 위치 좌표는 모델에 그대로
    /// 남겨 둔다.
    static func locationRing(
        stays: [PlaceStay],
        in span: TimeSpan,
        asOf: Date = .now
    ) -> RecordClockDetailRing? {
        let limit = min(span.end, asOf)
        guard span.start < limit else { return nil }
        let visibleSpan = TimeSpan(start: span.start, end: limit)
        let pieces = stays.compactMap { stay -> (token: String, span: TimeSpan)? in
            guard let visible = stay.span.intersection(with: visibleSpan),
                  visible.duration > 0 else { return nil }
            let name = stay.displayName
                .replacingOccurrences(of: "|", with: "/")
            let token = stay.floor.map { "\(name) · \($0)층" } ?? name
            return (token, visible)
        }
        return ring(kind: .location, pieces: pieces, in: span)
    }

    /// 겹친 단계 가운데 구체적인 관측이 이긴다. 경계마다 한 단계만 남겨
    /// 띠가 서로를 가리지 않게 한다.
    private static func resolvedStages(
        _ segments: [(stage: SleepStage, span: TimeSpan)]
    ) -> [(token: String, span: TimeSpan)] {
        let boundaries = Array(
            Set(segments.flatMap { [$0.span.start, $0.span.end] })
        ).sorted()
        guard boundaries.count >= 2 else { return [] }

        var result: [(token: String, span: TimeSpan)] = []
        for (start, end) in zip(boundaries, boundaries.dropFirst()) {
            guard start < end else { continue }
            let winner = segments
                .filter { $0.span.start < end && start < $0.span.end }
                .max { $0.stage.overlapPriority < $1.stage.overlapPriority }
            guard let winner else { continue }
            result.append(
                (winner.stage.rawValue, TimeSpan(start: start, end: end))
            )
        }
        return result
    }

    private static func ring(
        kind: RecordClockDetailKind,
        pieces: [(token: String, span: TimeSpan)],
        in span: TimeSpan
    ) -> RecordClockDetailRing? {
        let total = span.duration
        guard total > 0, !pieces.isEmpty else { return nil }

        var minimum = minimumArcFraction
        var condensed = condensed(pieces, minimumDuration: minimum * total)
        while condensed.count > maximumArcCount, minimum < 0.05 {
            minimum *= 2
            condensed = self.condensed(
                pieces,
                minimumDuration: minimum * total
            )
        }
        guard !condensed.isEmpty else { return nil }

        return RecordClockDetailRing(
            id: kind.rawValue,
            kind: kind,
            arcs: condensed.enumerated().map { offset, piece in
                RecordClockDetailArc(
                    id: "\(kind.rawValue).\(offset)",
                    token: piece.token,
                    startFraction: min(
                        1,
                        piece.span.start.timeIntervalSince(span.start) / total
                    ),
                    endFraction: min(
                        1,
                        piece.span.end.timeIntervalSince(span.start) / total
                    )
                )
            }
        )
    }

    /// 눈에 띄지 않을 만큼 짧은 조각은 그리지 않고 이웃에 합친다. 화소보다
    /// 얇은 조각을 수백 개 그리면 화면이 멈춘다. 붙어 있는 이웃이 없으면
    /// 최소 길이까지만 늘려 하나로 남긴다.
    private static func condensed(
        _ pieces: [(token: String, span: TimeSpan)],
        minimumDuration: TimeInterval
    ) -> [(token: String, span: TimeSpan)] {
        var merged: [(token: String, span: TimeSpan)] = []
        for piece in pieces.sorted(by: { $0.span.start < $1.span.start }) {
            guard let last = merged.last else {
                merged.append(piece)
                continue
            }
            let gap = piece.span.start.timeIntervalSince(last.span.end)
            guard gap < minimumDuration else {
                merged.append(piece)
                continue
            }
            if last.token == piece.token
                || piece.span.duration < minimumDuration {
                merged[merged.count - 1] = (
                    last.token,
                    TimeSpan(
                        start: last.span.start,
                        end: max(last.span.end, piece.span.end)
                    )
                )
            } else if last.span.duration < minimumDuration {
                // 앞 조각이 너무 짧으면 뒤 조각이 그 자리를 이어받는다.
                merged[merged.count - 1] = (
                    piece.token,
                    TimeSpan(start: last.span.start, end: piece.span.end)
                )
            } else {
                merged.append(piece)
            }
        }

        return merged.map { piece in
            guard piece.span.duration < minimumDuration else { return piece }
            return (
                piece.token,
                TimeSpan(
                    start: piece.span.start,
                    end: piece.span.start.addingTimeInterval(minimumDuration)
                )
            )
        }
    }
}

/// 원형 시간표는 재생 중 매 프레임 다시 그린다. 그때마다 하루를 다시 집계하면
/// 예산을 넘기므로, 이미 만들어 둔 고리를 자르고 고르는 일만 여기서 한다.
enum RecordClockEngine {
    /// 재생이 00시에서 24시까지 한 바퀴 도는 데 걸리는 시간. 오늘은 같은
    /// 속도로 현재 시각까지만 진행한다.
    static let sweepDuration: TimeInterval = 24

    /// 재생 중 화면 갱신 예산. 한 시간당 1초라 60Hz면 충분히 매끄럽다.
    static let frameInterval: TimeInterval = 1.0 / 60.0

    /// 24시간 눈금판에 표시하는 모든 시각.
    static let labeledHours = Array(0..<24)

    /// 가로로 이만큼 끌어야 날짜가 넘어간다.
    static let swipeThreshold: Double = 44

    /// 보고 있는 하루가 지금을 품을 때만 현재 시각 위치(0…1)를 준다.
    /// 오늘이 아니면 바늘을 그리지 않는다.
    static func nowFraction(in span: TimeSpan, asOf: Date = .now) -> Double? {
        let total = span.duration
        guard total > 0, span.start <= asOf, asOf < span.end else { return nil }
        return asOf.timeIntervalSince(span.start) / total
    }

    /// 과거 날짜는 24시, 오늘은 현재 시각, 미래 날짜는 00시까지만 재생한다.
    static func playbackEndFraction(
        in span: TimeSpan,
        asOf: Date = .now
    ) -> Double {
        guard span.duration > 0 else { return 0 }
        if asOf <= span.start { return 0 }
        if asOf >= span.end { return 1 }
        return asOf.timeIntervalSince(span.start) / span.duration
    }

    /// 재생 진행률. `endFraction`에 도달하면 더 진행하지 않는다.
    static func progress(
        start: Date?,
        now: Date,
        endFraction: Double = 1
    ) -> Double? {
        guard let start else { return nil }
        let end = endFraction.isFinite
            ? min(1, max(0, endFraction))
            : 1
        let elapsed = now.timeIntervalSince(start)
        guard elapsed.isFinite else { return 0 }
        guard elapsed > 0 else { return 0 }
        return min(end, elapsed / sweepDuration)
    }

    /// 자정이 위쪽인 24시간 시계에서 한 점의 시각 비율을 구한다.
    static func clockFraction(
        x: Double,
        y: Double,
        centerX: Double,
        centerY: Double
    ) -> Double {
        var fraction = (atan2(y - centerY, x - centerX) + .pi / 2)
            / (2 * .pi)
        fraction -= floor(fraction)
        return fraction
    }

    /// 범례에서 고른 카테고리만 남긴다. 고르지 않았으면 그대로 둔다.
    static func rings(
        _ rings: [RecordClockRing],
        isolating categoryID: String?
    ) -> [RecordClockRing] {
        guard let categoryID else { return rings }
        return rings.filter { $0.categoryID == categoryID }
    }

    /// 재생머리가 지난 만큼만 남긴다. 진행률이 nil이면 자르지 않는다.
    static func rings(
        _ rings: [RecordClockRing],
        revealedThrough progress: Double?
    ) -> [RecordClockRing] {
        guard let progress else { return rings }
        return rings.compactMap { ring in
            let arcs = ring.arcs.compactMap { arc -> RecordClockArc? in
                guard arc.startFraction < progress else { return nil }
                guard arc.endFraction > progress else { return arc }
                return RecordClockArc(
                    id: arc.id,
                    categoryID: arc.categoryID,
                    startFraction: arc.startFraction,
                    endFraction: progress
                )
            }
            guard !arcs.isEmpty else { return nil }
            return RecordClockRing(
                id: ring.id,
                categoryID: ring.categoryID,
                duration: ring.duration,
                arcs: arcs
            )
        }
    }

    /// 안쪽 띠도 재생머리를 따라 드러난다. 아직 아무것도 지나지 않았어도
    /// 띠 자체는 남겨야 눈금판에서 줄이 사라졌다 나타나지 않는다.
    static func detailRings(
        _ rings: [RecordClockDetailRing],
        revealedThrough progress: Double?
    ) -> [RecordClockDetailRing] {
        guard let progress else { return rings }
        return rings.map { ring in
            RecordClockDetailRing(
                id: ring.id,
                kind: ring.kind,
                arcs: ring.arcs.compactMap { arc in
                    guard arc.startFraction < progress else { return nil }
                    guard arc.endFraction > progress else { return arc }
                    return RecordClockDetailArc(
                        id: arc.id,
                        token: arc.token,
                        startFraction: arc.startFraction,
                        endFraction: progress
                    )
                }
            )
        }
    }

    /// 띠 하나짜리 바깥 고리도 같은 규칙으로 드러난다.
    static func detailRing(
        _ ring: RecordClockDetailRing?,
        revealedThrough progress: Double?
    ) -> RecordClockDetailRing? {
        guard let ring else { return nil }
        return detailRings([ring], revealedThrough: progress).first
    }

    /// 재생머리가 지금 지나고 있는 조각. 이 조각만 굵게 그리고, 이름과 시각을
    /// 읽음창에 적는다.
    static func arc(
        in ring: RecordClockDetailRing?,
        at fraction: Double
    ) -> RecordClockDetailArc? {
        ring?.arcs.first {
            $0.startFraction <= fraction && fraction < $0.endFraction
        }
    }

    /// 조각이 가리키는 실제 시각. 각도는 하루를 0…1로 나눈 값이라 되돌릴 때
    /// 초 단위로 반올림해야 8시 12분이 8시 11분 59초로 새지 않는다.
    static func span(
        of arc: RecordClockDetailArc,
        in span: TimeSpan
    ) -> TimeSpan {
        TimeSpan(
            start: date(at: arc.startFraction, in: span),
            end: date(at: arc.endFraction, in: span)
        )
    }

    /// 활동 고리의 조각을 사용자가 고른 실제 시각으로 되돌린다.
    static func span(
        of arc: RecordClockArc,
        in span: TimeSpan
    ) -> TimeSpan {
        TimeSpan(
            start: date(at: arc.startFraction, in: span),
            end: date(at: arc.endFraction, in: span)
        )
    }

    /// 읽음창이 적는 시각. 기록 상세·목표 화면이 구간을 적을 때와 같은 표기라
    /// 화면마다 시각을 다르게 읽지 않는다. 오전·오후를 떼면 눈금판이 24시간
    /// 판인데 6시가 두 번 생겨 읽는 사람이 어느 쪽인지 알 수 없다.
    static func timeRangeText(_ span: TimeSpan) -> String {
        "\(clockText(span.start))–\(clockText(span.end))"
    }

    private static func clockText(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    private static func date(at fraction: Double, in span: TimeSpan) -> Date {
        span.start.addingTimeInterval((fraction * span.duration).rounded())
    }

    /// 재생머리가 지금 지나고 있는 카테고리. 이 기록만 굵게 그린다.
    static func categoryIDs(
        in rings: [RecordClockRing],
        at fraction: Double
    ) -> Set<String> {
        var result: Set<String> = []
        for ring in rings where ring.arcs.contains(
            where: { $0.startFraction <= fraction && fraction < $0.endFraction }
        ) {
            result.insert(ring.categoryID)
        }
        return result
    }

    /// 가운데 고정 재생머리에서 스크롤한 거리와 하루 위치를 서로 바꾼다.
    static func playheadFraction(
        contentOffset: Double,
        timelineWidth: Double
    ) -> Double {
        guard timelineWidth > 0 else { return 0 }
        return min(1, max(0, contentOffset / timelineWidth))
    }

    static func contentOffset(
        for fraction: Double,
        timelineWidth: Double
    ) -> Double {
        max(0, timelineWidth) * min(1, max(0, fraction))
    }

    /// 가로로 충분히 끌었을 때만 날짜를 옮긴다. 왼쪽으로 끌면 다음 날이다.
    /// 세로가 더 길면 목록 스크롤이므로 날짜를 건드리지 않는다.
    static func swipeStep(
        width: Double,
        height: Double,
        threshold: Double = swipeThreshold
    ) -> Int? {
        guard abs(width) >= threshold, abs(width) > abs(height) else {
            return nil
        }
        return width < 0 ? 1 : -1
    }
}
