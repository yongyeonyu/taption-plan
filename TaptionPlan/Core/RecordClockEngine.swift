import Foundation
import TaptionPlanEngine

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

