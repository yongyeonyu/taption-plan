import CoreMotion
import MapKit
import Photos
import SwiftUI
import UserNotifications

/// 달력 점: 기록은 있지만 미확인 활동이 남은 날(빨강), 기록이 끝난 날(초록). 기록이 없으면 점이 없다.
enum MapHomeCalendarLogStatus: Equatable {
    case incomplete
    case complete
}

enum MapHomeCalendarLogStatusPolicy {
    /// `month`가 속한 달의 날짜별 상태. 센서·기록이 없는 날은 담지 않는다.
    static func statuses(
        actuals: [ActualRecord],
        travel: [TravelSegment],
        month: Date,
        asOf now: Date,
        calendar: Calendar
    ) -> [Date: MapHomeCalendarLogStatus] {
        guard let first = calendar.date(from: calendar.dateComponents([.year, .month], from: month)),
              let end = calendar.date(byAdding: .month, value: 1, to: first),
              let days = calendar.range(of: .day, in: .month, for: first) else { return [:] }
        let monthActuals = actuals.filter {
            let span = $0.span(asOf: now)
            return span.start < end && first < span.end
        }
        let monthTravel = travel.filter { $0.span.start < end && first < $0.span.end }
        guard !monthActuals.isEmpty || !monthTravel.isEmpty else { return [:] }
        var result: [Date: MapHomeCalendarLogStatus] = [:]
        for offset in 0..<days.count {
            guard let day = calendar.date(byAdding: .day, value: offset, to: first) else { continue }
            guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: day) else { continue }
            let hasRecord = monthActuals.contains {
                let span = $0.span(asOf: now)
                return span.start < dayEnd && day < span.end
            } || monthTravel.contains { $0.span.start < dayEnd && day < $0.span.end }
            guard hasRecord else { continue }
            let segments = MapHomeTimeRailSegmentEngine.segments(
                from: monthActuals, travel: monthTravel, on: day, asOf: now, calendar: calendar
            )
            guard !segments.isEmpty else { continue }
            result[day] = segments.contains { $0.categoryID == "unconfirmed" } ? .incomplete : .complete
        }
        return result
    }
}

/// 달력 하단 메뉴의 시간 종류. `rawValue`는 대분류 canonical 분류 ID와 같다(`DayPhase`).
enum MapHomeCalendarTimeKind: String, CaseIterable, Identifiable {
    case sleep, movement, study, work, exercise, hobby, distance, places, trips
    // 사용자가 "+"로 골라 쓰는 추가 지표
    case steps, photos, walkDistance, carDistance, transitDistance, awayTime, stepDistance, calories
    /// 가계부 수입·지출(원, LED1111A08). 지출은 실제로 쓴 돈(일상↔여행 이체 제외, 여행 중 지출 포함).
    case income, expense

    var id: String { rawValue }

    func title(_ language: MapHomeLanguage) -> String {
        switch self {
        case .sleep: language.text("수면시간", "Sleep")
        case .movement: language.text("이동시간", "Travel")
        case .study: language.text("수업시간", "Class")
        case .work: language.text("업무시간", "Work")
        case .exercise: language.text("운동시간", "Exercise")
        case .hobby: language.text("취미시간", "Hobby")
        case .distance: language.text("이동거리", "Distance")
        case .places: language.text("방문 장소", "Places")
        case .trips: language.text("이동 횟수", "Trips")
        case .steps: language.text("걸음 수", "Steps")
        case .photos: language.text("사진 수", "Photos")
        case .walkDistance: language.text("걷기 거리", "Walking")
        case .stepDistance: language.text("걸음 환산 거리", "Step distance")
        case .carDistance: language.text("운전 거리", "Driving")
        case .transitDistance: language.text("대중교통 거리", "Transit")
        case .awayTime: language.text("외출 시간", "Time away")
        case .calories: language.text("활동 칼로리", "Active calories")
        case .income: language.text("수입", "Income")
        case .expense: language.text("지출", "Spending")
        }
    }

    var systemImage: String {
        switch self {
        case .sleep: "moon.zzz.fill"
        case .movement: "figure.walk.motion"
        case .study: "graduationcap.fill"
        case .work: "briefcase.fill"
        case .exercise: "dumbbell.fill"
        case .hobby: "paintpalette.fill"
        case .distance: "point.topleft.down.to.point.bottomright.curvepath"
        case .places: "mappin.and.ellipse"
        case .trips: "arrow.left.arrow.right"
        case .steps: "figure.walk"
        case .photos: "photo.fill"
        case .walkDistance: "figure.walk.circle"
        case .stepDistance: "shoeprints.fill"
        case .carDistance: "car.fill"
        case .transitDistance: "tram.fill"
        case .awayTime: "door.left.hand.open"
        case .calories: "flame.fill"
        case .income: "plus.circle.fill"
        case .expense: "wonsign.circle.fill"
        }
    }

    /// 시간 합계는 초, 이동거리는 미터로 같은 딕셔너리에 담는다.
    var isDistance: Bool {
        self == .distance || self == .walkDistance || self == .carDistance || self == .transitDistance || self == .stepDistance
    }

    /// 방문 장소 수·이동 횟수·걸음 수·사진 수는 개수를 같은 딕셔너리에 담는다.
    var isCount: Bool { self == .places || self == .trips || self == .steps || self == .photos || self == .calories }

    /// 원 금액(가계부). 칸에는 짧게(1.2만), 자세히는 원으로.
    var isMoney: Bool { self == .income || self == .expense }

    /// 기본으로 늘 보이는 지표와, 사용자가 "+"로 더하는 지표.
    static let coreKinds: [MapHomeCalendarTimeKind] = [.sleep, .movement, .study, .work, .exercise, .hobby, .distance, .places, .trips]
    static let extraKinds: [MapHomeCalendarTimeKind] = [.steps, .photos, .walkDistance, .carDistance, .transitDistance, .awayTime, .stepDistance, .calories, .income, .expense]
    static let extraStorageKey = "mapHomeCalendarExtraKinds"
    /// 그날 칼로리가 걸음 수로 추정한 값이면 1. 합계 표의 지표 칸이 아니다.
    static let caloriesEstimatedKey = "caloriesEstimated"

    static func enabledExtras(from raw: String) -> [MapHomeCalendarTimeKind] {
        let enabled = Set(raw.split(separator: ",").map(String.init))
        return extraKinds.filter { enabled.contains($0.rawValue) }
    }

    static func raw(toggling kind: MapHomeCalendarTimeKind, in raw: String) -> String {
        var enabled = Set(raw.split(separator: ",").map(String.init))
        if enabled.contains(kind.rawValue) { enabled.remove(kind.rawValue) } else { enabled.insert(kind.rawValue) }
        return extraKinds.filter { enabled.contains($0.rawValue) }.map(\.rawValue).joined(separator: ",")
    }

    /// 시간 합계가 아닌 값(거리·개수)은 강조색으로 그린다.
    var usesAccentTint: Bool { isDistance || isCount }
}

/// 달력 "방문 장소"에 세는 한 곳. 같은 곳(30 m 이내)을 여러 번 들렀으면 한 줄로 합친다.
struct MapHomeCalendarPlaceVisit: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var buildingName: String?
    var arrival: Date
    var departure: Date
    var visitCount: Int
    var seconds: TimeInterval
    /// 등록 지점이면 그 종류의 앱 아이콘. 아니면 nil.
    var systemImage: String? = nil
}

enum MapHomeCalendarPlaceVisitPolicy {
    /// 한 번 머문 시간이 이 값보다 짧으면 방문으로 세지 않는다(스쳐 지난 곳).
    static let minimumStaySeconds: TimeInterval = 10 * 60
    /// 이 거리 안의 머묾은 같은 장소로 본다.
    static let samePlaceMeters: Double = 30

    /// `day`~`dayEnd`와 겹친 머묾 중 10분 이상인 것만, 30 m 안은 한 곳으로 묶어 도착 순서로 돌려준다.
    static func visits(
        stays: [PlaceStay],
        day: Date,
        dayEnd: Date,
        registeredNames: [String: String] = [:],
        registeredSymbols: [String: String] = [:]
    ) -> [MapHomeCalendarPlaceVisit] {
        struct Cluster {
            var anchor: GeoPoint?
            var key: String
            var names: [String: TimeInterval] = [:]
            var building: String?
            var arrival: Date
            var departure: Date
            var count = 0
            var seconds: TimeInterval = 0
        }
        var clusters: [Cluster] = []
        let ordered = stays
            .filter { $0.span.start < dayEnd && day < $0.span.end }
            .sorted { $0.span.start < $1.span.start }
        for stay in ordered {
            let start = max(stay.span.start, day)
            let end = min(stay.span.end, dayEnd)
            let duration = end.timeIntervalSince(start)
            guard duration >= minimumStaySeconds else { continue }
            let index = clusters.firstIndex { cluster in
                if let a = cluster.anchor, let b = stay.point { return distanceMeters(a, b) <= samePlaceMeters }
                return cluster.key == stay.placeKey
            }
            var cluster = index.map { clusters[$0] } ?? Cluster(
                anchor: stay.point, key: stay.placeKey, arrival: start, departure: end
            )
            // 등록 지점은 저장 당시 이름 대신 지금 등록한 이름을 쓴다.
            cluster.names[registeredNames[stay.placeKey] ?? stay.displayName, default: 0] += duration
            if cluster.building == nil { cluster.building = stay.buildingName }
            cluster.arrival = min(cluster.arrival, start)
            cluster.departure = max(cluster.departure, end)
            cluster.count += 1
            cluster.seconds += duration
            if let index { clusters[index] = cluster } else { clusters.append(cluster) }
        }
        return clusters.map { cluster in
            MapHomeCalendarPlaceVisit(
                id: cluster.key + "|\(cluster.arrival.timeIntervalSince1970)",
                name: cluster.names.max { $0.value < $1.value }?.key ?? cluster.key,
                buildingName: cluster.building,
                arrival: cluster.arrival,
                departure: cluster.departure,
                visitCount: cluster.count,
                seconds: cluster.seconds,
                systemImage: registeredSymbols[cluster.key]
            )
        }
        .sorted { $0.arrival < $1.arrival }
    }
}

enum MapHomeCalendarTimeTotalsPolicy {
    /// `month`가 속한 달의 날짜별·대분류별 시간(초). 오늘 이후와 기록이 없는 날은 담지 않는다.
    /// `sealed`에 있는 날은 저장해 둔 확정 요약을 그대로 쓰고 다시 계산하지 않는다.
    static func totals(
        actuals: [ActualRecord],
        travel: [TravelSegment],
        stays: [PlaceStay],
        placeKinds: [String: FrequentPlaceKind],
        month: Date,
        asOf now: Date,
        calendar: Calendar,
        sealed: [Date: TaptionSealedDay] = [:]
    ) -> [Date: [String: TimeInterval]] {
        guard let first = calendar.date(from: calendar.dateComponents([.year, .month], from: month)),
              let end = calendar.date(byAdding: .month, value: 1, to: first),
              let days = calendar.range(of: .day, in: .month, for: first) else { return [:] }
        let monthActuals = actuals.filter {
            let span = $0.span(asOf: now)
            return span.start < end && first < span.end
        }
        let monthTravel = travel.filter { $0.span.start < end && first < $0.span.end }
        let monthStays = stays.filter { $0.span.start < end && first < $0.span.end }
        // 확정 요약만 있는 달(원본을 백업으로 옮긴 달)도 값이 나와야 한다.
        guard !monthActuals.isEmpty || !monthTravel.isEmpty || !monthStays.isEmpty || !sealed.isEmpty else {
            return [:]
        }

        let homeKeys = Set(placeKinds.filter { $0.value == .home }.keys)
        var result: [Date: [String: TimeInterval]] = [:]
        for offset in 0..<days.count {
            guard let day = calendar.date(byAdding: .day, value: offset, to: first),
                  day <= now,
                  let dayEnd = calendar.date(byAdding: .day, value: 1, to: day) else { continue }
            // 확정한 날은 다시 계산하지 않는다.
            if let digest = sealed[calendar.startOfDay(for: day)] {
                var values = digest.metrics.mapValues { TimeInterval($0) }
                for (id, seconds) in digest.categorySeconds where id != "unconfirmed" {
                    values[id] = TimeInterval(seconds)
                }
                if !values.isEmpty { result[day] = values }
                continue
            }
            let byID = dayTotals(
                actuals: monthActuals,
                travel: monthTravel,
                stays: monthStays,
                placeKinds: placeKinds,
                homeKeys: homeKeys,
                day: day,
                dayEnd: dayEnd,
                asOf: now
            )
            if !byID.isEmpty { result[day] = byID }
        }
        return result
    }

    /// 하루치 달력 지표(대분류별 초 + 거리·장소·이동 횟수·외출 시간). 확정 요약도 이 값을 그대로 담는다.
    static func dayTotals(
        actuals: [ActualRecord],
        travel: [TravelSegment],
        stays: [PlaceStay],
        placeKinds: [String: FrequentPlaceKind],
        day: Date,
        dayEnd: Date,
        asOf now: Date
    ) -> [String: TimeInterval] {
        dayTotals(
            actuals: actuals,
            travel: travel,
            stays: stays,
            placeKinds: placeKinds,
            homeKeys: Set(placeKinds.filter { $0.value == .home }.keys),
            day: day,
            dayEnd: dayEnd,
            asOf: now
        )
    }

    private static func dayTotals(
        actuals: [ActualRecord],
        travel: [TravelSegment],
        stays: [PlaceStay],
        placeKinds: [String: FrequentPlaceKind],
        homeKeys: Set<String>,
        day: Date,
        dayEnd: Date,
        asOf now: Date
    ) -> [String: TimeInterval] {
        let phases = DayPhaseEngine.completePhases(
            actuals: actuals,
            travel: travel,
            stays: stays,
            placeKinds: placeKinds,
            in: TimeSpan(start: day, end: dayEnd),
            asOf: now
        )
        var byID: [String: TimeInterval] = [:]
        for entry in DayPhaseEngine.categoryDurations(phases, scope: .canonical) where entry.actual > 0 && entry.categoryID != "unconfirmed" {
            byID[entry.categoryID, default: 0] += entry.actual
        }
        let meters = distanceMeters(of: travel, in: TimeSpan(start: day, end: dayEnd))
        if meters >= 10 { byID[MapHomeCalendarTimeKind.distance.rawValue] = meters }
        let dayStays = stays.filter { $0.span.start < dayEnd && day < $0.span.end }
        let placeCount = MapHomeCalendarPlaceVisitPolicy.visits(stays: dayStays, day: day, dayEnd: dayEnd).count
        if placeCount > 0 { byID[MapHomeCalendarTimeKind.places.rawValue] = Double(placeCount) }
        let tripCount = travel.filter { $0.span.start < dayEnd && day < $0.span.end }.count
        if tripCount > 0 { byID[MapHomeCalendarTimeKind.trips.rawValue] = Double(tripCount) }
        let daySpan = TimeSpan(start: day, end: dayEnd)
        let walkMeters = distanceMeters(of: travel.filter { $0.mode == .walking || $0.mode == .running }, in: daySpan)
        if walkMeters >= 10 { byID[MapHomeCalendarTimeKind.walkDistance.rawValue] = walkMeters }
        let carMeters = distanceMeters(of: travel.filter { $0.mode == .car || $0.mode == .taxi }, in: daySpan)
        if carMeters >= 10 { byID[MapHomeCalendarTimeKind.carDistance.rawValue] = carMeters }
        let transitMeters = distanceMeters(
            of: travel.filter { $0.mode == .bus || $0.mode == .subway || $0.mode == .train },
            in: daySpan
        )
        if transitMeters >= 10 { byID[MapHomeCalendarTimeKind.transitDistance.rawValue] = transitMeters }
        let dayTravel = travel.filter { $0.span.start < dayEnd && day < $0.span.end }
        if let away = awaySeconds(stays: dayStays, travel: dayTravel, homeKeys: homeKeys, day: day, dayEnd: min(dayEnd, now)), away > 0 {
            byID[MapHomeCalendarTimeKind.awayTime.rawValue] = away
        }
        return byID
    }

    /// 한 구간의 대분류별 시간(초). 연봉 카운터가 오늘 근무 시간만 빠르게 다시 셀 때 쓴다.
    static func categorySeconds(
        actuals: [ActualRecord],
        travel: [TravelSegment],
        stays: [PlaceStay],
        placeKinds: [String: FrequentPlaceKind],
        in span: TimeSpan,
        asOf now: Date
    ) -> [String: TimeInterval] {
        let phases = DayPhaseEngine.completePhases(
            actuals: actuals.filter { let s = $0.span(asOf: now); return s.start < span.end && span.start < s.end },
            travel: travel.filter { $0.span.start < span.end && span.start < $0.span.end },
            stays: stays.filter { $0.span.start < span.end && span.start < $0.span.end },
            placeKinds: placeKinds,
            in: span,
            asOf: now
        )
        var byID: [String: TimeInterval] = [:]
        for entry in DayPhaseEngine.categoryDurations(phases, scope: .canonical) where entry.actual > 0 && entry.categoryID != "unconfirmed" {
            byID[entry.categoryID, default: 0] += entry.actual
        }
        return byID
    }

    /// 날짜별 걸음 수 합치기: 건강 앱 값(기기 간 겹침을 HealthKit이 정리한 합계)을 우선하고, 없는 날만 센서 값.
    /// 걷기 순에너지 근사(kcal/kg/km). 건강 앱 값이 없는 날의 추정에만 쓴다.
    static let walkingKilocaloriesPerKilogramKilometer = 0.5
    static let defaultWeightKilograms = 65.0

    /// 날짜별 활동 칼로리. 건강 앱(Watch·iPhone 겹침 정리됨)을 우선하고, 없는 날만 걸음으로 추정한다.
    static func dailyCalories(
        health: [Date: Double],
        steps: [Date: Double],
        strideMeters: Double,
        weightKilograms: Double?
    ) -> [Date: (kilocalories: Double, isEstimated: Bool)] {
        let weight = weightKilograms.flatMap { $0 > 0 ? $0 : nil } ?? defaultWeightKilograms
        var result: [Date: (kilocalories: Double, isEstimated: Bool)] = [:]
        for (day, stepCount) in steps where stepCount > 0 {
            let kilometers = stepCount * strideMeters / 1_000
            result[day] = (walkingKilocaloriesPerKilogramKilometer * weight * kilometers, true)
        }
        for (day, value) in health where value > 0 { result[day] = (value, false) }
        return result
    }

    static func mergedStepCounts(health: [Date: Double], sensor: [Date: Double]) -> [Date: Double] {
        ClassifierAdapter.mergedDailySteps(health: health, sensor: sensor)
    }

    /// 그 달 날짜별 사진 수. `moments`는 기간 안 사진을 읽는 함수(사진 접근 권한이 없으면 빈 배열).
    static func photoCounts(
        in month: Date,
        moments: (TimeSpan) -> [PhotoMoment],
        calendar: Calendar
    ) -> [Date: Double] {
        guard let first = calendar.date(from: calendar.dateComponents([.year, .month], from: month)),
              let end = calendar.date(byAdding: .month, value: 1, to: first) else { return [:] }
        var result: [Date: Double] = [:]
        for moment in moments(TimeSpan(start: first, end: end)) {
            result[calendar.startOfDay(for: moment.capturedAt), default: 0] += 1
        }
        return result
    }

    /// 집 밖에 있던 시간(초) = 집 밖 체류 + 이동. 기록 공백은 외출로 세지 않는다.
    /// 그날 체류 기록이나 집 등록이 없으면 nil.
    static func awaySeconds(stays: [PlaceStay], travel: [TravelSegment] = [], homeKeys: Set<String>, day: Date, dayEnd: Date) -> TimeInterval? {
        guard dayEnd > day else { return nil }
        return ClassifierAdapter.awaySeconds(stays: stays, travel: travel, homeKeys: homeKeys, in: TimeSpan(start: day, end: dayEnd))
    }

    /// 하루와 겹치는 이동 구간의 거리(미터). 구간이 날을 걸치면 겹친 시간 비율만큼만 더한다.
    static func distanceMeters(of travel: [TravelSegment], in day: TimeSpan) -> Double {
        travel.reduce(0) { sum, segment in
            guard segment.distanceMeters.isFinite, segment.distanceMeters > 0 else { return sum }
            let total = segment.span.end.timeIntervalSince(segment.span.start)
            let overlap = min(segment.span.end, day.end).timeIntervalSince(max(segment.span.start, day.start))
            guard overlap > 0 else { return sum }
            return sum + (total > 0 ? segment.distanceMeters * min(1, overlap / total) : segment.distanceMeters)
        }
    }

    /// 자세한 금액(원). 메인 액터 밖에서도 쓴다.
    static func moneyText(_ amount: Double, language: MapHomeLanguage) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        let number = formatter.string(from: NSNumber(value: amount.rounded())) ?? String(Int(amount.rounded()))
        return language.text("\(number)원", "₩\(number)")
    }

    /// 달력 칸의 금액 표기(원). 1만 이상은 「1.2만」, 영어는 「12k」. 0은 빈 문자열.
    static func moneyCellText(_ amount: Double, language: MapHomeLanguage) -> String {
        guard amount >= 1 else { return "" }
        if language == .korean {
            return amount >= 10_000 ? String(format: amount >= 100_000 ? "%.0f만" : "%.1f만", amount / 10_000) : String(Int(amount.rounded()))
        }
        return amount >= 1_000 ? String(format: amount >= 100_000 ? "%.0fk" : "%.1fk", amount / 1_000) : String(Int(amount.rounded()))
    }

    /// 달력 칸의 개수 표기. 0은 빈 문자열.
    static func countCellText(count: Double) -> String {
        guard count >= 1 else { return "" }
        return count >= 1_000 ? String(format: "%.1fk", count / 1_000) : String(Int(count.rounded()))
    }

    static func countText(count: Double, kind: MapHomeCalendarTimeKind, language: MapHomeLanguage) -> String {
        let value = Int(count.rounded())
        switch kind {
        case .places: return language.text("\(value)곳", "\(value)")
        case .steps: return language.text("\(value)걸음", "\(value) steps")
        case .calories: return "\(value) kcal"
        case .photos: return language.text("\(value)장", "\(value)")
        default: return language.text("\(value)회", "\(value)")
        }
    }

    static func distanceCellText(meters: Double) -> String {
        guard meters >= 10 else { return "" }
        return meters < 1_000 ? "\(Int(meters.rounded()))m" : String(format: "%.1fk", meters / 1_000)
    }

    static func distanceText(meters: Double) -> String {
        AppRegion.current.distanceText(meters: meters)
    }

    /// 달력 칸의 짧은 표기: 1시간 이상은 `7:20`, 한 시간 미만은 `45m`. 0은 빈 문자열.
    static func cellText(seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        guard minutes > 0 else { return "" }
        if minutes < 60 { return "\(minutes)m" }
        let remainder = minutes % 60
        return remainder == 0 ? "\(minutes / 60)h" : "\(minutes / 60):\(String(format: "%02d", remainder))"
    }

    static func durationText(seconds: TimeInterval, language: MapHomeLanguage) -> String {
        let minutes = Int((seconds / 60).rounded())
        guard minutes > 0 else { return language.text("0분", "0 min") }
        let hours = minutes / 60, remainder = minutes % 60
        if hours == 0 { return language.text("\(remainder)분", "\(remainder) min") }
        if remainder == 0 { return language.text("\(hours)시간", "\(hours) h") }
        return language.text("\(hours)시간 \(remainder)분", "\(hours) h \(remainder) min")
    }
}

/// A compact month selector used by the map home header.
///
/// The sheet deliberately owns only calendar presentation. Holiday dates are
/// supplied by the caller so the same verified holiday source can be reused by
/// the timeline and other date pickers.
/// 달력을 다시 열 때 첫 화면부터 값이 차 있고 달 계산을 되풀이하지 않게 달별로 기억한다(SHT1102A01).
/// 최근 `limit`개월만 둔다. 값은 시트가 다 올라온 뒤 새로 읽어 덮어쓴다.
struct MapHomeCalendarMonthMemory {
    struct DayInfo: Equatable {
        let day: Int
        let weekday: Int
        let holiday: String?
    }

    private struct Month {
        var statuses: [Date: MapHomeCalendarLogStatus] = [:]
        var totals: [Date: [String: TimeInterval]] = [:]
        var days: [Date?]?
        var dayInfo: [Date: DayInfo] = [:]
        var titles: [String: String] = [:]
    }

    @MainActor static var shared = MapHomeCalendarMonthMemory()

    let limit: Int
    /// 내용 높이. 처음 레이아웃부터 시트 높이 후보를 맞춰 올라오는 도중 다시 계산하지 않게 한다.
    var contentHeight: CGFloat = 0
    private var months: [Date: Month] = [:]
    private var order: [Date] = []

    init(limit: Int = 6) {
        self.limit = limit
    }

    func statuses(for month: Date) -> [Date: MapHomeCalendarLogStatus] { months[month]?.statuses ?? [:] }
    func totals(for month: Date) -> [Date: [String: TimeInterval]] { months[month]?.totals ?? [:] }

    mutating func store(statuses: [Date: MapHomeCalendarLogStatus], for month: Date) {
        update(month) { $0.statuses = statuses }
    }

    mutating func store(totals: [Date: [String: TimeInterval]], for month: Date) {
        update(month) { $0.totals = totals }
    }

    mutating func days(for month: Date, make: () -> [Date?]) -> [Date?] {
        if let days = months[month]?.days { return days }
        let days = make()
        update(month) { $0.days = days }
        return days
    }

    mutating func dayInfo(for date: Date, in month: Date, make: () -> DayInfo) -> DayInfo {
        if let info = months[month]?.dayInfo[date] { return info }
        let info = make()
        update(month) { $0.dayInfo[date] = info }
        return info
    }

    mutating func title(for month: Date, key: String, make: () -> String) -> String {
        if let title = months[month]?.titles[key] { return title }
        let title = make()
        update(month) { $0.titles[key] = title }
        return title
    }

    private mutating func update(_ month: Date, _ change: (inout Month) -> Void) {
        order.removeAll { $0 == month }
        order.append(month)
        change(&months[month, default: Month()])
        while order.count > limit {
            months[order.removeFirst()] = nil
        }
    }
}
