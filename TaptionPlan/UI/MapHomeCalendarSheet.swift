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
    case steps, photos, walkDistance, carDistance, transitDistance, awayTime, stepDistance

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
        }
    }

    /// 시간 합계는 초, 이동거리는 미터로 같은 딕셔너리에 담는다.
    var isDistance: Bool {
        self == .distance || self == .walkDistance || self == .carDistance || self == .transitDistance || self == .stepDistance
    }

    /// 방문 장소 수·이동 횟수·걸음 수·사진 수는 개수를 같은 딕셔너리에 담는다.
    var isCount: Bool { self == .places || self == .trips || self == .steps || self == .photos }

    /// 기본으로 늘 보이는 지표와, 사용자가 "+"로 더하는 지표.
    static let coreKinds: [MapHomeCalendarTimeKind] = [.sleep, .movement, .study, .work, .exercise, .hobby, .distance, .places, .trips]
    static let extraKinds: [MapHomeCalendarTimeKind] = [.steps, .photos, .walkDistance, .carDistance, .transitDistance, .awayTime, .stepDistance]
    static let extraStorageKey = "mapHomeCalendarExtraKinds"

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

enum MapHomeCalendarTimeTotalsPolicy {
    /// `month`가 속한 달의 날짜별·대분류별 시간(초). 오늘 이후와 기록이 없는 날은 담지 않는다.
    static func totals(
        actuals: [ActualRecord],
        travel: [TravelSegment],
        stays: [PlaceStay],
        placeKinds: [String: FrequentPlaceKind],
        month: Date,
        asOf now: Date,
        calendar: Calendar
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
        guard !monthActuals.isEmpty || !monthTravel.isEmpty || !monthStays.isEmpty else { return [:] }
        let homeKeys = Set(placeKinds.filter { $0.value == .home }.keys)
        var result: [Date: [String: TimeInterval]] = [:]
        for offset in 0..<days.count {
            guard let day = calendar.date(byAdding: .day, value: offset, to: first),
                  day <= now,
                  let dayEnd = calendar.date(byAdding: .day, value: 1, to: day) else { continue }
            let phases = DayPhaseEngine.completePhases(
                actuals: monthActuals,
                travel: monthTravel,
                stays: monthStays,
                placeKinds: placeKinds,
                in: TimeSpan(start: day, end: dayEnd),
                asOf: now
            )
            var byID: [String: TimeInterval] = [:]
            for entry in DayPhaseEngine.categoryDurations(phases, scope: .canonical) where entry.actual > 0 && entry.categoryID != "unconfirmed" {
                byID[entry.categoryID, default: 0] += entry.actual
            }
            let meters = distanceMeters(of: monthTravel, in: TimeSpan(start: day, end: dayEnd))
            if meters >= 10 { byID[MapHomeCalendarTimeKind.distance.rawValue] = meters }
            let dayStays = monthStays.filter { $0.span.start < dayEnd && day < $0.span.end }
            let placeCount = Set(dayStays.map(\.placeKey)).count
            if placeCount > 0 { byID[MapHomeCalendarTimeKind.places.rawValue] = Double(placeCount) }
            let tripCount = monthTravel.filter { $0.span.start < dayEnd && day < $0.span.end }.count
            if tripCount > 0 { byID[MapHomeCalendarTimeKind.trips.rawValue] = Double(tripCount) }
            let daySpan = TimeSpan(start: day, end: dayEnd)
            let walkMeters = distanceMeters(of: monthTravel.filter { $0.mode == .walking || $0.mode == .running }, in: daySpan)
            if walkMeters >= 10 { byID[MapHomeCalendarTimeKind.walkDistance.rawValue] = walkMeters }
            let carMeters = distanceMeters(of: monthTravel.filter { $0.mode == .car || $0.mode == .taxi }, in: daySpan)
            if carMeters >= 10 { byID[MapHomeCalendarTimeKind.carDistance.rawValue] = carMeters }
            let transitMeters = distanceMeters(
                of: monthTravel.filter { $0.mode == .bus || $0.mode == .subway || $0.mode == .train },
                in: daySpan
            )
            if transitMeters >= 10 { byID[MapHomeCalendarTimeKind.transitDistance.rawValue] = transitMeters }
            if let away = awaySeconds(stays: dayStays, homeKeys: homeKeys, day: day, dayEnd: min(dayEnd, now)), away > 0 {
                byID[MapHomeCalendarTimeKind.awayTime.rawValue] = away
            }
            if !byID.isEmpty { result[day] = byID }
        }
        return result
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

    /// 날짜별 걸음 수 합치기: 건강 앱 값과 센서 값 중 큰 쪽(둘 다 같은 걸음의 다른 측정이라 더하지 않는다).
    static func mergedStepCounts(health: [Date: Double], sensor: [Date: Double]) -> [Date: Double] {
        health.merging(sensor) { max($0, $1) }
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

    /// 집 밖에 있던 시간(초). 집으로 등록한 장소의 체류를 뺀 나머지이고, 그날 체류 기록이나 집 등록이 없으면 nil.
    static func awaySeconds(stays: [PlaceStay], homeKeys: Set<String>, day: Date, dayEnd: Date) -> TimeInterval? {
        guard !homeKeys.isEmpty, !stays.isEmpty, dayEnd > day else { return nil }
        let homeSeconds = stays.filter { homeKeys.contains($0.placeKey) }.reduce(0.0) { sum, stay in
            sum + max(0, min(stay.span.end, dayEnd).timeIntervalSince(max(stay.span.start, day)))
        }
        return max(0, dayEnd.timeIntervalSince(day) - homeSeconds)
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
        case .photos: return language.text("\(value)장", "\(value)")
        default: return language.text("\(value)회", "\(value)")
        }
    }

    static func distanceCellText(meters: Double) -> String {
        guard meters >= 10 else { return "" }
        return meters < 1_000 ? "\(Int(meters.rounded()))m" : String(format: "%.1fk", meters / 1_000)
    }

    static func distanceText(meters: Double) -> String {
        meters < 1_000 ? "\(Int(meters.rounded())) m" : String(format: "%.1f km", meters / 1_000)
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
struct MapHomeCalendarSheet: View {
    @Binding private var selectedDate: Date
    private let holidayName: (Date) -> String?
    private let logStatuses: (Date) async -> [Date: MapHomeCalendarLogStatus]
    private let timeTotals: (Date) async -> [Date: [String: TimeInterval]]
    private let timeTint: (String) -> Color
    private let language: MapHomeLanguage
    private let calendar: Calendar

    @State private var displayedMonth: Date
    @State private var statuses: [Date: MapHomeCalendarLogStatus] = [:]
    @Environment(\.displayScale) private var displayScale
    @AppStorage(MapHomeCalendarTimeKind.extraStorageKey) private var extraKindsRaw = ""
    @State private var selectedKind: MapHomeCalendarTimeKind?
    @State private var contentHeight: CGFloat = 0
    /// 새 센서 기록이 들어올 때마다 바뀌는 값. 바뀌면 이번 달 지표를 바로 다시 읽는다.
    private let liveToken: Double
    private let liveTotals: (Date) async -> [Date: [String: TimeInterval]]
    @State private var totals: [Date: [String: TimeInterval]] = [:]

    init(
        selectedDate: Binding<Date>,
        holidayName: @escaping (Date) -> String?,
        logStatuses: @escaping (Date) async -> [Date: MapHomeCalendarLogStatus] = { _ in [:] },
        timeTotals: @escaping (Date) async -> [Date: [String: TimeInterval]] = { _ in [:] },
        liveTotals: (@escaping (Date) async -> [Date: [String: TimeInterval]]) = { _ in [:] },
        timeTint: @escaping (String) -> Color = { _ in Color.tpAccent },
        language: MapHomeLanguage = .korean,
        liveToken: Double = 0
    ) {
        self.liveToken = liveToken
        self._selectedDate = selectedDate
        self.holidayName = holidayName
        self.logStatuses = logStatuses
        self.timeTotals = timeTotals
        self.liveTotals = liveTotals
        self.timeTint = timeTint
        self.language = language

        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = language.locale
        calendar.timeZone = .current
        calendar.firstWeekday = 1
        self.calendar = calendar

        let day = calendar.startOfDay(for: selectedDate.wrappedValue)
        self._displayedMonth = State(initialValue: calendar.date(
            from: calendar.dateComponents([.year, .month], from: day)
        ) ?? day)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 20)
                    .padding(.top, 18)

                weekdayHeader
                    .padding(.horizontal, 16)
                    .padding(.top, 18)

                monthGrid
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                timeMenu
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                if let selectedKind {
                    timePanel(for: selectedKind)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                }
            }
            .padding(.bottom, 40)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .frame(maxWidth: .infinity)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.tpBackground)
        // 지표 패널·여섯 번째 주가 늘어도 아래 여백까지 한 화면에 보이도록 높이를 내용에 맞춘다.
        .presentationDetents(contentHeight > 0 ? [.height(contentHeight + 16), .large] : [.height(selectedKind == nil ? 540 : 700), .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color.tpBackground)
        // 달이 바뀔 때뿐 아니라 "+"로 지표를 켜고 끌 때도 다시 읽는다(걸음·사진은 켠 때만 읽기 때문).
        .task(id: "\(displayedMonth.timeIntervalSince1970)|\(extraKindsRaw)") {
            totals = [:]
            if !statuses.isEmpty { statuses = [:] }
            let month = displayedMonth
            let monthStatuses = await logStatuses(month)
            guard !Task.isCancelled, month == displayedMonth else { return }
            statuses = monthStatuses
            let value = await timeTotals(month)
            guard !Task.isCancelled, month == displayedMonth else { return }
            totals = value
        }
        // 이번 달을 보고 있으면 걸음 수·이동 거리처럼 GPS로 빨리 바뀌는 값은 새 센서 기록이 들어올 때마다(약 1초 안에) 다시 읽는다.
        .task(id: "\(displayedMonth.timeIntervalSince1970)|\(liveToken)") {
            guard isShowingCurrentMonth else { return }
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            let month = displayedMonth
            let fast = await liveTotals(month)
            guard !Task.isCancelled, month == displayedMonth, !fast.isEmpty else { return }
            // 시간 합계·사진 수 같은 값은 30초 갱신에 맡기고, 걸음 수와 이동 거리만 덮어쓴다.
            let fastKeys: Set<String> = [
                MapHomeCalendarTimeKind.steps, .distance, .walkDistance, .carDistance, .transitDistance, .stepDistance,
            ].reduce(into: []) { $0.insert($1.rawValue) }
            for (day, values) in fast {
                totals[day, default: [:]].merge(values.filter { fastKeys.contains($0.key) }) { _, new in new }
            }
        }
        // 각종 시간 합계·사진 수·기록 상태는 화면을 보는 동안 30초마다 다시 읽는다(분 단위 시간이 30초 안에 반영됨).
        .task(id: displayedMonth) {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled, isShowingCurrentMonth else { continue }
                let month = displayedMonth
                let monthStatuses = await logStatuses(month)
                let value = await timeTotals(month)
                guard !Task.isCancelled, month == displayedMonth else { return }
                statuses = monthStatuses
                totals = value
            }
        }
    }

    private var isShowingCurrentMonth: Bool {
        MapHomeGrowthPolicy.localCalendar.isDate(displayedMonth, equalTo: .now, toGranularity: .month)
    }

    private func cellValueText(_ kind: MapHomeCalendarTimeKind, on date: Date) -> String {
        let value = seconds(of: kind, on: date)
        if kind.isCount { return MapHomeCalendarTimeTotalsPolicy.countCellText(count: value) }
        return kind.isDistance
            ? MapHomeCalendarTimeTotalsPolicy.distanceCellText(meters: value)
            : MapHomeCalendarTimeTotalsPolicy.cellText(seconds: value)
    }

    private func seconds(of kind: MapHomeCalendarTimeKind, on date: Date) -> TimeInterval {
        totals[calendar.startOfDay(for: date)]?[kind.rawValue] ?? 0
    }

    private var timeMenu: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            ForEach(MapHomeCalendarTimeKind.coreKinds + MapHomeCalendarTimeKind.enabledExtras(from: extraKindsRaw)) { kind in
                let isOn = selectedKind == kind
                let tint = kind.usesAccentTint ? Color.tpAccent : timeTint(kind.rawValue)
                Button {
                    selectedKind = isOn ? nil : kind
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: kind.systemImage)
                            .font(.system(size: 13, weight: .semibold))
                        Text(kind.title(language))
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(isOn ? tint : Color.tpInk)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(isOn ? tint.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(isOn ? tint : Color.tpLine, lineWidth: isOn ? 1.2 : 0.8)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(kind.title(language))
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
            addMetricMenu
        }
    }

    /// "+" 타일: 걸음 수·사진 수·수단별 거리·외출 시간을 골라 달력 지표로 더하거나 뺀다.
    private var addMetricMenu: some View {
        Menu {
            ForEach(MapHomeCalendarTimeKind.extraKinds) { kind in
                let isEnabled = MapHomeCalendarTimeKind.enabledExtras(from: extraKindsRaw).contains(kind)
                Button {
                    extraKindsRaw = MapHomeCalendarTimeKind.raw(toggling: kind, in: extraKindsRaw)
                    if isEnabled, selectedKind == kind { selectedKind = nil }
                } label: {
                    Label(kind.title(language), systemImage: isEnabled ? "checkmark" : kind.systemImage)
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                Text(language.text("추가", "Add"))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(Color.tpSecondary)
            .frame(maxWidth: .infinity, minHeight: 44)
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.tpLine, style: StrokeStyle(lineWidth: 0.8, dash: [4, 3]))
            }
        }
        .accessibilityLabel(language.text("지표 추가", "Add metric"))
    }

    private func panelText(_ value: Double, for kind: MapHomeCalendarTimeKind) -> String {
        if kind.isCount {
            return MapHomeCalendarTimeTotalsPolicy.countText(count: value, kind: kind, language: language)
        }
        return kind.isDistance
            ? MapHomeCalendarTimeTotalsPolicy.distanceText(meters: value)
            : MapHomeCalendarTimeTotalsPolicy.durationText(seconds: value, language: language)
    }

    private func timePanel(for kind: MapHomeCalendarTimeKind) -> some View {
        let tint = kind.usesAccentTint ? Color.tpAccent : timeTint(kind.rawValue)
        let daysInMonth = calendar.range(of: .day, in: .month, for: displayedMonth)?.count ?? 30
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: displayedMonth)) ?? displayedMonth
        let days = (0..<daysInMonth).compactMap { calendar.date(byAdding: .day, value: $0, to: monthStart) }
        let values = days.map { day in day <= Date.now ? seconds(of: kind, on: day) : 0 }
        let elapsedDays = max(1, days.filter { $0 <= Date.now }.count)
        let sum = values.reduce(0, +)
        let maxValue = max(values.max() ?? 0, 1)
        let selected = calendar.startOfDay(for: selectedDate)
        let selectedInMonth = calendar.isDate(selected, equalTo: monthStart, toGranularity: .month)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(kind.title(language))
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.tpInk)
                Spacer()
                if selectedInMonth {
                    Text(language.text("\(calendar.component(.month, from: selected))월 \(calendar.component(.day, from: selected))일",
                                       selected.formatted(.dateTime.month(.abbreviated).day())))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.tpSecondary)
                }
            }
            Text(panelText(selectedInMonth ? seconds(of: kind, on: selected) : 0, for: kind))
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(tint)
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(tint.opacity(calendar.isDate(day, inSameDayAs: selected) ? 1 : 0.4))
                        .frame(height: max(2, 44 * values[index] / maxValue))
                }
            }
            .frame(height: 44, alignment: .bottom)
            .overlay(alignment: .bottom) {
                // 하루 평균: 50% 흐린 1픽셀 선을 모든 항목의 그래프에 긋는다.
                Rectangle()
                    .fill(tint.opacity(0.5))
                    .frame(height: 1 / displayScale)
                    .offset(y: -min(44, 44 * (sum / Double(elapsedDays)) / maxValue))
            }
            HStack(spacing: 8) {
                timeStat(language.text("이번 달 합계", "Month total"),
                         panelText(sum, for: kind))
                timeStat(language.text("하루 평균", "Daily average"),
                         panelText(sum / Double(elapsedDays), for: kind))
            }
        }
        .padding(12)
        .background(Color.tpSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.tpLine.opacity(0.9), lineWidth: 0.8) }
    }

    private func timeStat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(Color.tpSecondary)
            Text(value).font(.system(size: 14, weight: .bold, design: .rounded)).foregroundStyle(Color.tpInk)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.tpBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var header: some View {
        HStack {
            Button {
                shiftMonth(by: -1)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.tpInk)
                    .frame(width: 34, height: 34)
                    .background(Color.tpBackground, in: Circle())
            }
            .accessibilityLabel(language.text("이전 달", "Previous month"))

            Spacer(minLength: 12)

            Button {
                jumpToToday()
            } label: {
                Text(monthTitle)
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.tpInk)
                    .padding(.horizontal, 8)
                    .frame(minHeight: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(monthTitle)
            .accessibilityHint(language.text("누르면 오늘 날짜로 이동합니다", "Jumps to today"))

            Spacer(minLength: 12)

            Button {
                shiftMonth(by: 1)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.tpInk)
                    .frame(width: 34, height: 34)
                    .background(Color.tpBackground, in: Circle())
            }
            .accessibilityLabel(language.text("다음 달", "Next month"))
        }
    }

    private var weekdayHeader: some View {
        let weekdays = language == .korean
            ? ["일", "월", "화", "수", "목", "금", "토"]
            : ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        return LazyVGrid(columns: gridColumns, spacing: 0) {
            ForEach(Array(weekdays.enumerated()), id: \.offset) { index, weekday in
                VStack(spacing: 2) {
                    Image(weekdayIconName(index: index))
                        .resizable()
                        .scaledToFit()
                        .frame(width: 18, height: 18)
                        .accessibilityHidden(true)

                    Text(weekday)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(weekdayColor(index: index))
                }
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var monthGrid: some View {
        LazyVGrid(columns: gridColumns, spacing: 7) {
            ForEach(monthDays, id: \.self) { date in
                if let date {
                    dayCell(for: date)
                } else {
                    Color.clear
                        .frame(maxWidth: .infinity, minHeight: 38)
                }
            }
        }
    }

    private func dayCell(for date: Date) -> some View {
        let day = calendar.component(.day, from: date)
        let weekday = calendar.component(.weekday, from: date)
        let holiday = holidayName(date)
        let isSelected = calendar.isDate(date, inSameDayAs: selectedDate)
        let isToday = calendar.isDateInToday(date)
        let status = statuses[calendar.startOfDay(for: date)]

        return Button {
            selectedDate = date
        } label: {
            VStack(spacing: 2) {
                Text(String(day))
                    .font(.system(size: 15, weight: isSelected ? .bold : .regular, design: .rounded))
                    .foregroundStyle(isSelected ? Color.white : dayColor(weekday: weekday, holiday: holiday))
                    .frame(width: 32, height: 28)
                    .background {
                        if isSelected {
                            Circle().fill(Color.tpAccent)
                        } else if isToday {
                            Circle().stroke(Color.tpAccent.opacity(0.65), lineWidth: 1.5)
                        }
                    }

                if let selectedKind {
                    Text(cellValueText(selectedKind, on: date))
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(selectedKind.usesAccentTint ? Color.tpAccent : timeTint(selectedKind.rawValue))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(height: 12)
                } else {
                    Circle()
                        .fill(logDotColor(status))
                        .frame(width: 4, height: 4)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 38)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel(day: day, date: date, holiday: holiday, status: status))
    }

    private var monthDays: [Date?] {
        guard let firstDay = calendar.date(from: calendar.dateComponents([.year, .month], from: displayedMonth)),
              let dayRange = calendar.range(of: .day, in: .month, for: firstDay)
        else { return [] }

        let leading = calendar.component(.weekday, from: firstDay) - calendar.firstWeekday
        let normalizedLeading = (leading + 7) % 7
        let dates = dayRange.compactMap { day -> Date? in
            calendar.date(byAdding: .day, value: day - 1, to: firstDay)
        }
        return Array(repeating: nil, count: normalizedLeading) + dates
    }

    private var monthTitle: String {
        let formatter = DateFormatter()
        formatter.locale = language.locale
        formatter.calendar = calendar
        formatter.dateFormat = language.monthTitleFormat
        return formatter.string(from: displayedMonth)
    }

    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)
    }

    /// 월 제목을 누르면 오늘 날짜를 선택하고 그 달로 돌아온다.
    private func jumpToToday() {
        let today = calendar.startOfDay(for: .now)
        selectedDate = today
        displayedMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: today)) ?? today
    }

    private func shiftMonth(by value: Int) {
        guard let date = calendar.date(byAdding: .month, value: value, to: displayedMonth) else { return }
        displayedMonth = date
    }

    private func weekdayColor(index: Int) -> Color {
        index == 0 ? .tpHoliday : index == 6 ? .tpSaturday : .tpSecondary
    }

    private func weekdayIconName(index: Int) -> String {
        switch index {
        case 0: "MapHomeCalendarSunday"
        case 1: "MapHomeCalendarMonday"
        case 2: "MapHomeCalendarTuesday"
        case 3: "MapHomeCalendarWednesday"
        case 4: "MapHomeCalendarThursday"
        case 5: "MapHomeCalendarFriday"
        default: "MapHomeCalendarSaturday"
        }
    }

    private func dayColor(weekday: Int, holiday: String?) -> Color {
        if holiday != nil || weekday == 1 { return .tpHoliday }
        if weekday == 7 { return .tpSaturday }
        return .tpInk
    }

    private func logDotColor(_ status: MapHomeCalendarLogStatus?) -> Color {
        switch status {
        case .incomplete: .tpHoliday
        case .complete: Color(red: 0.25, green: 0.70, blue: 0.40)
        case nil: .clear
        }
    }

    private func accessibilityLabel(
        day: Int, date: Date, holiday: String?, status: MapHomeCalendarLogStatus?
    ) -> String {
        var title = language == .korean
            ? "\(monthTitle) \(day)일"
            : "\(monthTitle) \(day)"
        if let holiday { title += ", \(holiday)" }
        switch status {
        case .incomplete: title += language.text(", 미확인 활동 있음", ", unconfirmed activity")
        case .complete: title += language.text(", 기록 완료", ", fully logged")
        case nil: break
        }
        return title
    }
}

/// 등록지점 범위의 들어옴·나감 판정. 반경의 ±15%는 히스테리시스 구간으로, 이 안에서는 이전 상태를 그대로 둔다.
/// 그래서 경계에서 흔들리는 GPS 값이 "나감·들어옴"을 반복 만들지 않는다.
enum MapHomePlaceZone {
    static let band = 0.15

    enum State: Equatable {
        case inside
        case outside
    }

    /// 한 번의 거리 측정으로 다음 상태를 정한다.
    /// 안쪽 85%보다 가까우면 안, 바깥쪽 115%보다 멀면 밖, 그 사이는 이전 상태 유지.
    static func next(distance: Double, radius: Double, previous: State) -> State {
        guard radius > 0, distance.isFinite else { return previous }
        if distance <= radius * (1 - band) { return .inside }
        if distance >= radius * (1 + band) { return .outside }
        return previous
    }

    /// 장소 판정 샘플: 시각, 장소 중심까지 거리, 움직이는 중인지.
    struct Sample {
        let date: Date
        let distance: Double
        let isMoving: Bool
    }

    /// 도착·출발 확정 결과.
    enum Event: Equatable {
        /// 안으로 들어온 뒤 `dwell` 동안 계속 안에 머물렀다.
        case arrived(Date)
        /// 밖으로 나간 뒤 움직이며 멀어졌다(이동 확인).
        case departed(Date)
    }

    /// 들어옴 후 머무름, 나감 후 이동을 확인해 도착·출발을 확정한다.
    /// - 도착: 안쪽 전환 뒤 `dwell`(기본 5분) 동안 밖으로 나가지 않을 때만.
    /// - 출발: 바깥쪽 전환 뒤 `moveWindow`(기본 10분) 안에 움직이는 측정이 있을 때만.
    static func events(
        samples: [Sample],
        radius: Double,
        dwell: TimeInterval = 5 * 60,
        moveWindow: TimeInterval = 10 * 60
    ) -> [Event] {
        let ordered = samples.sorted { $0.date < $1.date }
        let changes = transitions(
            samples: ordered.map { (date: $0.date, distance: $0.distance) },
            radius: radius
        )
        var events: [Event] = []
        for change in changes {
            let after = ordered.filter { $0.date >= change.date }
            switch change.state {
            case .inside:
                // 다음 바깥쪽 전환 전에 dwell만큼 흘렀는지 본다(샘플이 dwell 이후까지 있어야 한다).
                let nextOut = changes.first { $0.date > change.date && $0.state == .outside }?.date
                let deadline = change.date.addingTimeInterval(dwell)
                let stayed = (nextOut ?? .distantFuture) >= deadline
                    && (after.last?.date ?? change.date) >= deadline
                if stayed { events.append(.arrived(change.date)) }
            case .outside:
                let window = after.filter { $0.date <= change.date.addingTimeInterval(moveWindow) }
                // 멀어졌다는 것만으로는 부족하다. 실제로 움직인 측정이 있어야 출발로 본다.
                let moved = window.contains { $0.isMoving }
                if moved { events.append(.departed(change.date)) }
            }
        }
        return events
    }

    /// 시간 순 측정열에서 상태가 바뀐 시각만 골라 돌려준다. 처음 상태는 밖으로 본다.
    static func transitions(
        samples: [(date: Date, distance: Double)],
        radius: Double
    ) -> [(date: Date, state: State)] {
        var current = State.outside
        var result: [(date: Date, state: State)] = []
        for sample in samples.sorted(by: { $0.date < $1.date }) {
            let updated = next(distance: sample.distance, radius: radius, previous: current)
            if updated != current {
                result.append((sample.date, updated))
                current = updated
            }
        }
        return result
    }
}

/// 걸음 수를 거리로 바꾸는 보폭(m). 기본값은 대표가 알려주는 값으로 바꾼다.
enum MapHomeStride {
    static let storageKey = "mapHomeStrideMeters"
    static let defaultMeters = 20.0 / 26.5
    static let allowedRange = 0.3...1.5

    static var current: Double {
        let stored = UserDefaults.standard.double(forKey: storageKey)
        return allowedRange.contains(stored) ? stored : defaultMeters
    }

    /// 걸어간 거리(m)와 그때의 걸음 수로 보폭을 구한다. 값이 비정상이면 nil.
    static func calibrated(distanceMeters: Double, steps: Int) -> Double? {
        guard steps >= 5, distanceMeters > 0 else { return nil }
        let stride = distanceMeters / Double(steps)
        return allowedRange.contains(stride) ? stride : nil
    }
}

/// 보폭 보정: 시작 → 정해진 거리를 걷기 → 종료 → 거리 입력으로 보폭을 저장한다. 직접 입력도 된다.
struct MapHomeStrideCalibrationSheet: View {
    let language: MapHomeLanguage
    @AppStorage(MapHomeStride.storageKey) private var strideMeters = MapHomeStride.defaultMeters
    @State private var pedometer = CMPedometer()
    @State private var isMeasuring = false
    @State private var steps = 0
    @State private var distanceText = "10"
    @State private var manualCentimeters = ""
    @State private var message: String?

    private var currentStride: Double {
        MapHomeStride.allowedRange.contains(strideMeters) ? strideMeters : MapHomeStride.defaultMeters
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(language.text("보폭 보정", "Stride calibration"))
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                Text(language.text(
                    "현재 보폭 \(String(format: "%.0f", currentStride * 100))cm · 걸음 수 × 보폭으로 걸음 환산 거리를 계산합니다.",
                    "Stride \(String(format: "%.0f", currentStride * 100)) cm · used for step-based distance."
                ))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.tpSecondary)

                VStack(alignment: .leading, spacing: 10) {
                    Text(language.text("1. 시작을 누르고 정한 거리를 걸은 뒤 종료를 누르세요.", "1. Tap Start, walk a known distance, then tap Stop."))
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                    Text(language.text("\(steps)걸음", "\(steps) steps"))
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Button(isMeasuring ? language.text("종료", "Stop") : language.text("시작", "Start")) {
                        isMeasuring ? stop() : start()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(isMeasuring ? Color.tpHoliday : Color.tpAccent)
                    HStack {
                        Text(language.text("2. 걸은 거리", "2. Distance walked"))
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                        TextField("10", text: $distanceText)
                            .keyboardType(.decimalPad)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                        Text("m")
                        Spacer()
                        Button(language.text("보폭 저장", "Save")) { saveMeasured() }
                            .buttonStyle(.bordered)
                            .disabled(isMeasuring || steps < 5)
                    }
                }
                .padding(14)
                .background(Color.tpSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                HStack {
                    Text(language.text("직접 입력", "Manual"))
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                    TextField("75", text: $manualCentimeters)
                        .keyboardType(.decimalPad)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                    Text("cm")
                    Spacer()
                    Button(language.text("저장", "Save")) { saveManual() }.buttonStyle(.bordered)
                }
                if let message {
                    Text(message).font(.system(size: 13, weight: .medium)).foregroundStyle(Color.tpAccent)
                }
            }
            .padding(22)
        }
        .background(Color.tpBackground)
        .onDisappear { pedometer.stopUpdates() }
    }

    private func start() {
        guard CMPedometer.isStepCountingAvailable() else {
            message = language.text("이 기기에서는 걸음 수를 쓸 수 없습니다.", "Step counting is unavailable on this device.")
            return
        }
        steps = 0
        message = nil
        isMeasuring = true
        pedometer.startUpdates(from: Date()) { data, error in
            Task { @MainActor in
                if let data {
                    steps = data.numberOfSteps.intValue
                } else if error != nil {
                    // 동작·피트니스 권한이 없거나 측정이 막혔을 때 멈추고 이유를 보여 준다.
                    pedometer.stopUpdates()
                    isMeasuring = false
                    message = language.text(
                        "걸음 측정을 할 수 없어요. 설정에서 동작 및 피트니스 권한을 허용해 주세요.",
                        "Steps unavailable. Allow Motion & Fitness in Settings."
                    )
                }
            }
        }
    }

    private func stop() {
        pedometer.stopUpdates()
        isMeasuring = false
    }

    private func number(_ text: String) -> Double? {
        Double(text.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces))
    }

    private func saveMeasured() {
        guard let distance = number(distanceText),
              let stride = MapHomeStride.calibrated(distanceMeters: distance, steps: steps) else {
            message = language.text("거리나 걸음 수가 맞지 않습니다(보폭 30~150cm).", "Distance or steps look wrong (stride 30–150 cm).")
            return
        }
        strideMeters = stride
        message = language.text("보폭 \(String(format: "%.0f", stride * 100))cm로 저장했습니다.", "Saved \(String(format: "%.0f", stride * 100)) cm.")
    }

    private func saveManual() {
        guard let centimeters = number(manualCentimeters), MapHomeStride.allowedRange.contains(centimeters / 100) else {
            message = language.text("30~150cm 사이로 입력해 주세요.", "Enter 30–150 cm.")
            return
        }
        strideMeters = centimeters / 100
        message = language.text("보폭 \(String(format: "%.0f", centimeters))cm로 저장했습니다.", "Saved \(String(format: "%.0f", centimeters)) cm.")
    }
}

/// 땅 타일(집 주변 땅 따먹기). 화면이 지저분해 보여 대표 결정으로 숨긴다. 보상 데이터는 그대로 둔다.
enum MapHomeLandFeature {
    static let isVisible = false
}

/// 세전 월급에서 근로자가 내는 4대보험·소득세를 빼 세후 월급을 추정한다(2026년 요율, 근로소득 간이세액 방식).
/// 부양가족 본인 1명, 비과세 식대 월 20만 원을 가정한다. 실제 공제액은 회사 정산에 따라 다를 수 있다.
enum MapHomeKoreanNetPay {
    static let mealAllowance = 200_000.0
    static let pensionRate = 0.0475
    static let pensionBase = 400_000.0...6_370_000.0
    static let healthRate = 0.03595
    static let careRateOfHealth = 0.1314
    static let employmentRate = 0.009

    struct Breakdown: Equatable {
        var gross: Double
        var pension: Double
        var health: Double
        var care: Double
        var employment: Double
        var incomeTax: Double
        var localTax: Double
        var net: Double { gross - pension - health - care - employment - incomeTax - localTax }
    }

    static func monthly(gross: Double) -> Breakdown {
        guard gross > 0 else { return Breakdown(gross: 0, pension: 0, health: 0, care: 0, employment: 0, incomeTax: 0, localTax: 0) }
        let taxable = max(0, gross - min(gross, mealAllowance))
        let pension = min(max(taxable, pensionBase.lowerBound), pensionBase.upperBound) * pensionRate
        let health = taxable * healthRate
        let care = health * careRateOfHealth
        let employment = taxable * employmentRate
        let annualTax = annualIncomeTax(totalPay: taxable * 12, annualPension: pension * 12)
        let incomeTax = (annualTax / 12 / 10).rounded(.down) * 10
        let localTax = (incomeTax * 0.1 / 10).rounded(.down) * 10
        return Breakdown(gross: gross, pension: pension, health: health, care: care, employment: employment, incomeTax: incomeTax, localTax: localTax)
    }

    /// 연간 결정세액(지방소득세 제외).
    static func annualIncomeTax(totalPay s: Double, annualPension: Double) -> Double {
        let earnedDeduction = min(20_000_000, {
            switch s {
            case ..<5_000_000: return s * 0.7
            case ..<15_000_000: return 3_500_000 + (s - 5_000_000) * 0.4
            case ..<45_000_000: return 7_500_000 + (s - 15_000_000) * 0.15
            case ..<100_000_000: return 12_000_000 + (s - 45_000_000) * 0.05
            default: return 14_750_000 + (s - 100_000_000) * 0.02
            }
        }())
        // 간이세액표의 특별소득공제 등(공제대상가족 1명) 산식.
        let special: Double = {
            switch s {
            case ..<30_000_000: return 3_100_000 + s * 0.04
            case ..<45_000_000: return 3_100_000 + s * 0.04 - (s - 30_000_000) * 0.05
            case ..<70_000_000: return 3_100_000 + s * 0.015
            case ..<120_000_000: return 3_100_000 + s * 0.005
            default: return 0
            }
        }()
        let base = max(0, s - earnedDeduction - 1_500_000 - annualPension - special)
        let brackets: [(limit: Double, rate: Double)] = [
            (14_000_000, 0.06), (50_000_000, 0.15), (88_000_000, 0.24), (150_000_000, 0.35),
            (300_000_000, 0.38), (500_000_000, 0.40), (1_000_000_000, 0.42), (.infinity, 0.45),
        ]
        var computed = 0.0, lower = 0.0
        for bracket in brackets where base > lower {
            computed += (min(base, bracket.limit) - lower) * bracket.rate
            lower = bracket.limit
        }
        let credit = computed <= 1_300_000 ? computed * 0.55 : 715_000 + (computed - 1_300_000) * 0.3
        let creditLimit: Double = {
            switch s {
            case ...33_000_000: return 740_000
            case ...70_000_000: return max(660_000, 740_000 - (s - 33_000_000) * 0.008)
            case ...120_000_000: return max(500_000, 660_000 - (s - 70_000_000) * 0.5)
            default: return max(200_000, 500_000 - (s - 120_000_000) * 0.5)
            }
        }()
        return max(0, computed - min(credit, creditLimit))
    }
}

/// 연봉 카운터: 업무 시간에 시급을 곱해 번 돈을 보여 준다(금액은 원).
enum MapHomeSalaryPolicy {
    static let annualKey = "mapHomeSalaryAnnual"
    static let monthlyPayKey = "mapHomeSalaryMonthlyPay"
    static let isNetInputKey = "mapHomeSalaryIsNetInput"
    static let showsNetKey = "mapHomeSalaryShowsNet"
    static let isHourlyKey = "mapHomeSalaryIsHourly"
    static let hourlyKey = "mapHomeSalaryHourly"
    static let hourlyTaxKey = "mapHomeSalaryHourlyTax"
    static let weeklyHolidayKey = "mapHomeSalaryWeeklyHoliday"
    static let hourlyIsNetKey = "mapHomeSalaryHourlyIsNet"
    static let monthAccumKey = "mapHomeSalaryMonthAccum"
    static let monthAccumMonthKey = "mapHomeSalaryMonthAccumMonth"
    /// 달별로 실제 받은 월급(수당 포함, 입력 기준). JSON `{"2026-09": 2900000}`.
    static let payHistoryKey = "mapHomeSalaryPayHistory"
    /// 기록이 없을 때 쓰는 법정 연장수당 배율(통상시급 × 1.5).
    static let defaultOvertimeMultiplier = 1.5
    /// 한 달 근무가 이보다 적게 잡히면 그 달 기록은 수당 추정에 쓰지 않는다.
    static let minimumSampleHours = 20.0
    static let tickKey = "mapHomeSalaryTickSeconds"
    static let tickChoices = [1, 10, 30, 60, 300, 600, 1_800, 3_600]
    /// 주 40시간 기준 월 소정근로시간(주휴 포함).
    static let standardMonthlyHours = 209.0
    static let workKey = MapHomeCalendarTimeKind.work.rawValue
    static let movementKey = MapHomeCalendarTimeKind.movement.rawValue

    /// 시급 알바의 세금 계산 방식. 하나만 고른다.
    enum HourlyTax: String, CaseIterable {
        case threePointThree
        case fourInsurance
        case none

        /// 세후 비율. 4대보험은 국민연금·건강(장기요양 포함)·고용보험 근로자 부담분을 뺀다.
        var keepRate: Double {
            switch self {
            case .threePointThree: 1 - 0.033
            case .fourInsurance: 1 - (MapHomeKoreanNetPay.pensionRate + MapHomeKoreanNetPay.healthRate * (1 + MapHomeKoreanNetPay.careRateOfHealth) + MapHomeKoreanNetPay.employmentRate)
            case .none: 1
            }
        }
    }

    struct Settings: Equatable {
        var annualPay = 0.0
        /// 입력한 연봉·월급이 세후 금액인지.
        var isNetInput = false
        /// 0이면 연봉 ÷ 12.
        var monthlyPay = 0.0
        /// 세전 입력일 때 세후로 계산해 보여 줄지.
        var showsNet = true
        /// 이번 달 누적 금액을 직접 고친 값(0이면 근무 시간으로 계산).
        var monthAccumOverride = 0.0
        /// 달별 실제 받은 월급(수당 포함).
        var payHistory: [String: Double] = [:]
        /// 시급으로 입력했는지. 연봉·월급과 하나만 쓴다.
        var isHourly = false
        var hourly = 0.0
        var hourlyTax: HourlyTax = .threePointThree
        /// 주 15시간 이상 근무면 주휴수당을 시급에 더한다.
        var includesWeeklyHoliday = false
        /// 시급을 세후로 입력했는지(세전이면 false).
        var hourlyIsNet = false

        var isConfigured: Bool { isHourly ? hourly > 0 : annualPay > 0 || monthlyPay > 0 }
        var showsNetAmounts: Bool { showsNet }
    }

    static func monthKey(_ date: Date, calendar: Calendar = MapHomeGrowthPolicy.localCalendar) -> String {
        let c = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }

    static func loadSettings(_ defaults: UserDefaults = .standard, now: Date = .now) -> Settings {
        let override = defaults.string(forKey: monthAccumMonthKey) == monthKey(now) ? defaults.double(forKey: monthAccumKey) : 0
        return Settings(
            annualPay: defaults.double(forKey: annualKey),
            isNetInput: defaults.bool(forKey: isNetInputKey),
            monthlyPay: defaults.double(forKey: monthlyPayKey),
            showsNet: defaults.object(forKey: showsNetKey) as? Bool ?? true,
            monthAccumOverride: override,
            payHistory: decodePayHistory(defaults.string(forKey: payHistoryKey) ?? ""),
            isHourly: defaults.bool(forKey: isHourlyKey),
            hourly: defaults.double(forKey: hourlyKey),
            hourlyTax: HourlyTax(rawValue: defaults.string(forKey: hourlyTaxKey) ?? "") ?? .threePointThree,
            includesWeeklyHoliday: defaults.bool(forKey: weeklyHolidayKey),
            hourlyIsNet: defaults.bool(forKey: hourlyIsNetKey)
        )
    }

    static func decodePayHistory(_ raw: String) -> [String: Double] {
        (try? JSONDecoder().decode([String: Double].self, from: Data(raw.utf8))) ?? [:]
    }

    static func encodePayHistory(_ history: [String: Double]) -> String {
        (try? String(data: JSONEncoder().encode(history.filter { $0.value > 0 }), encoding: .utf8)) ?? "{}"
    }

    /// 받은 월급 기록은 실수령(세후)으로 적고, 입력 기준(세전 또는 세후)에 맞춰 짝을 만든다.
    static func paySamples(_ settings: Settings, pastMonthWorkSeconds: [String: TimeInterval]) -> [PaySample] {
        settings.payHistory.compactMap { key, received in
            pastMonthWorkSeconds[key].map {
                PaySample(hours: $0 / 3_600, pay: settings.isNetInput ? received : grossFromNetMonthly(received))
            }
        }
    }

    /// 지난 어느 달의 (근무 시간, 받은 월급) 한 쌍.
    struct PaySample: Equatable {
        var hours: Double
        var pay: Double
    }

    /// 월급 = 고정분 + 209시간을 넘긴 1시간당 수당. 지난달 기록으로 맞춘다.
    struct PayModel: Equatable {
        var fixedMonthly: Double
        var overtimeHourly: Double
        /// 맞추는 데 쓴 달 수(0이면 법정 1.5배 기본값).
        var sampleCount: Int
    }

    /// 지난달들의 (근무 시간, 받은 월급)에 직선을 맞춘다: 받은 월급 = 고정분 + 수당시급 × (근무 − 209시간).
    /// 기록이 2개월 이상이고 근무 시간이 서로 다르면 최소제곱, 1개월이면 그 달로 수당시급만, 없으면 통상시급 × 1.5.
    /// 수당시급은 0~통상시급 3배, 고정분은 기본 월급의 0.5~2배로 묶어 이상값을 막는다.
    static func fitPayModel(baseMonthly: Double, samples: [PaySample]) -> PayModel {
        let baseHourly = baseMonthly / standardMonthlyHours
        let defaultOvertime = baseHourly * defaultOvertimeMultiplier
        let usable = samples.filter { $0.hours >= minimumSampleHours && $0.pay > 0 }
        func clampOvertime(_ v: Double) -> Double { min(max(v, 0), baseHourly * 3) }
        func clampFixed(_ v: Double) -> Double { min(max(v, baseMonthly * 0.5), baseMonthly * 2) }
        guard !usable.isEmpty else { return PayModel(fixedMonthly: baseMonthly, overtimeHourly: defaultOvertime, sampleCount: 0) }
        let xs = usable.map { $0.hours - standardMonthlyHours }
        let ys = usable.map(\.pay)
        let n = Double(usable.count)
        let meanX = xs.reduce(0, +) / n, meanY = ys.reduce(0, +) / n
        let varX = zip(xs, xs).reduce(0) { $0 + ($1.0 - meanX) * ($1.1 - meanX) }
        if usable.count >= 2, varX > 1 {
            let cov = zip(xs, ys).reduce(0) { $0 + ($1.0 - meanX) * ($1.1 - meanY) }
            let slope = clampOvertime(cov / varX)
            return PayModel(fixedMonthly: clampFixed(meanY - slope * meanX), overtimeHourly: slope, sampleCount: usable.count)
        }
        // 근무 시간이 다 비슷하면 기울기를 못 구한다: 고정분만 기록 평균으로 보정하고 수당은 기본값.
        if abs(meanX) < 1 {
            return PayModel(fixedMonthly: clampFixed(meanY), overtimeHourly: defaultOvertime, sampleCount: usable.count)
        }
        let slope = clampOvertime((meanY - baseMonthly) / meanX)
        return PayModel(fixedMonthly: baseMonthly, overtimeHourly: slope, sampleCount: usable.count)
    }

    /// 그 달 근무 시간으로 받을 월급(입력 기준). 209시간 미만이어도 고정분은 다 받는 것으로 본다.
    static func expectedMonthlyPay(_ model: PayModel, workHours: Double) -> Double {
        model.fixedMonthly + model.overtimeHourly * max(0, workHours - standardMonthlyHours)
    }

    /// 입력 기준 금액을 보여 줄 기준으로 바꾼다(세전 입력 + 세후 보기면 공제).
    static func displayed(_ amount: Double, _ settings: Settings) -> Double {
        if settings.isNetInput { return settings.showsNet ? amount : grossFromNetMonthly(amount) }
        return settings.showsNet ? MapHomeKoreanNetPay.monthly(gross: amount).net : amount
    }

    /// 세후 월급에서 세전 월급을 거꾸로 구한다. 세후는 세전에 따라 단조 증가하므로 이분법으로 맞춘다.
    static func grossFromNetMonthly(_ net: Double) -> Double {
        guard net > 0 else { return 0 }
        var low = 0.0, high = net * 3
        for _ in 0..<60 {
            let mid = (low + high) / 2
            if MapHomeKoreanNetPay.monthly(gross: mid).net < net { low = mid } else { high = mid }
        }
        return (low + high) / 2
    }

    /// 입력 기준과 무관하게 세전 월급·세후 월급.
    static func monthlyGross(_ settings: Settings) -> Double {
        settings.isNetInput ? grossFromNetMonthly(inputMonthly(settings)) : inputMonthly(settings)
    }

    static func monthlyNet(_ settings: Settings) -> Double {
        settings.isNetInput ? inputMonthly(settings) : MapHomeKoreanNetPay.monthly(gross: inputMonthly(settings)).net
    }

    /// 입력 기준(세전 또는 세후)의 월급.
    static func inputMonthly(_ settings: Settings) -> Double {
        if settings.isHourly { return 0 }
        return settings.monthlyPay > 0 ? settings.monthlyPay : settings.annualPay / 12
    }

    /// 보여 줄 기준의 월급. 세전 입력을 세후로 보면 4대보험·소득세를 뺀다.
    static func displayedMonthly(_ settings: Settings) -> Double {
        displayed(inputMonthly(settings), settings)
    }

    /// 연봉·시급 연동용: 시급 모드여도 연봉·월급 입력의 세전 월급(시급 모드면 저장된 연봉 기준).
    static func monthlyGrossIgnoringHourly(_ settings: Settings) -> Double {
        let base = settings.monthlyPay > 0 ? settings.monthlyPay : settings.annualPay / 12
        return settings.isNetInput ? grossFromNetMonthly(base) : base
    }

    /// 시급을 쓰면 시급의 연봉 환산(월 209시간 × 12), 연봉을 쓰면 연봉의 세전 시급 환산(÷ 209). 한쪽만 적어도 다른 쪽이 나온다.
    static func linkedAnnualGross(_ settings: Settings) -> Double {
        let fromAnnual = monthlyGrossIgnoringHourly(settings) * 12
        return fromAnnual > 0 ? fromAnnual : hourlyGross(settings, weeklyHours: 0) * standardMonthlyHours * 12
    }

    static func linkedHourlyGross(_ settings: Settings) -> Double {
        settings.hourly > 0 ? hourlyGross(settings, weeklyHours: 0) : monthlyGrossIgnoringHourly(settings) / standardMonthlyHours
    }

    /// 세전 → 세후(4대보험·소득세) 환산 금액.
    static func netOfGross(_ gross: Double) -> Double {
        MapHomeKoreanNetPay.monthly(gross: gross / 12).net * 12
    }

    /// 1,234,567 형식으로 묶는다. 숫자가 아니면 빈 문자열.
    static func grouped(_ text: String) -> String {
        guard let value = Int(text.filter(\.isNumber)) else { return "" }
        return value.formatted(.number.locale(Locale(identifier: "en_US")).grouping(.automatic))
    }

    /// 시급의 세전 금액. 세후로 입력했으면 세율을 거꾸로 적용하고, 주휴수당(주 15시간 이상이면 min(주 근무 ÷ 5, 8)시간분)을 더한다.
    static func hourlyGross(_ settings: Settings, weeklyHours: Double) -> Double {
        var gross = settings.hourlyIsNet ? settings.hourly / settings.hourlyTax.keepRate : settings.hourly
        if settings.includesWeeklyHoliday, weeklyHours >= 15 {
            gross *= 1 + min(weeklyHours / 5, 8) / weeklyHours
        }
        return gross
    }

    /// 표시 기준(세전/세후)에 맞춘 시급.
    static func hourlyDisplayed(_ settings: Settings, weeklyHours: Double) -> Double {
        let gross = hourlyGross(settings, weeklyHours: weeklyHours)
        return settings.showsNet ? gross * settings.hourlyTax.keepRate : gross
    }

    /// 월급 ÷ 209시간.
    static func baseHourlyRate(_ settings: Settings) -> Double? {
        if settings.isHourly { return settings.hourly > 0 ? hourlyDisplayed(settings, weeklyHours: 0) : nil }
        let monthly = displayedMonthly(settings)
        return monthly > 0 ? monthly / standardMonthlyHours : nil
    }

    /// 이번 달 지금까지 번 돈. 직접 고친 값이 있으면 그 값.
    static func accumulated(_ settings: Settings, monthWorkSeconds: TimeInterval) -> Double {
        if settings.monthAccumOverride > 0 { return settings.monthAccumOverride }
        return earnings(workSeconds: monthWorkSeconds, hourlyRate: baseHourlyRate(settings) ?? 0)
    }

    /// 이번 달 받을 것으로 보는 월급(보여 줄 기준): 지난달 기록으로 맞춘 수당 모델에 예상 근무 시간을 넣는다.
    static func expectedMonthPay(_ settings: Settings, projectedMonthWorkSeconds: TimeInterval, samples: [PaySample]) -> Double? {
        let base = inputMonthly(settings)
        guard base > 0 else { return nil }
        let model = fitPayModel(baseMonthly: base, samples: samples)
        let hours = max(projectedMonthWorkSeconds, 0) / 3_600
        return displayed(expectedMonthlyPay(model, workHours: hours), settings)
    }

    /// 시급은 주식처럼 움직인다: 이번 달 예상 월급(수당 포함) ÷ 이번 달 예상 근무 시간.
    /// 예상 근무는 지금까지 + 추세로 예측한 남은 근무, 예상 월급은 지난달 기록으로 맞춘 고정분 + 초과 수당이라
    /// 야근이 늘면 월급과 시간이 함께 올라가고, 월말에는 예상 = 실제가 되어 누적이 그 달 월급과 맞아떨어진다.
    /// 누적 금액을 직접 고쳤으면 그 금액 ÷ 지금까지 근무 시간(1시간 이상일 때).
    static func hourlyRate(
        _ settings: Settings,
        monthWorkSeconds: TimeInterval,
        projectedMonthWorkSeconds: TimeInterval,
        samples: [PaySample] = []
    ) -> Double? {
        if settings.isHourly {
            guard settings.hourly > 0 else { return nil }
            let weeklyHours = max(projectedMonthWorkSeconds, monthWorkSeconds) / 3_600 * 7 / 30.4
            return hourlyDisplayed(settings, weeklyHours: weeklyHours)
        }
        let monthly = displayedMonthly(settings)
        guard monthly > 0 else { return nil }
        if settings.monthAccumOverride > 0, monthWorkSeconds >= 3_600 {
            return settings.monthAccumOverride / (monthWorkSeconds / 3_600)
        }
        let projected = max(projectedMonthWorkSeconds, monthWorkSeconds)
        guard projected >= 3_600 else { return monthly / standardMonthlyHours }
        let pay = expectedMonthPay(settings, projectedMonthWorkSeconds: projected, samples: samples) ?? monthly
        return pay / (projected / 3_600)
    }

    /// 업무 시간 추세로 이번 달 총 근무 시간을 예측한다. 남은 날은 최근 8주 같은 요일의 평균 근무(기록 있는 날만)로,
    /// 오늘은 "지금까지"와 요일 평균 중 큰 쪽으로 본다. 요일 기록이 없으면 평일 평균, 그것도 없으면 0.
    static func projectedMonthWorkSeconds(
        dailyWork: [Date: TimeInterval],
        now: Date,
        calendar: Calendar
    ) -> TimeInterval {
        guard let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now)),
              let monthEnd = calendar.date(byAdding: .month, value: 1, to: monthStart) else { return 0 }
        let today = calendar.startOfDay(for: now)
        let historyStart = calendar.date(byAdding: .day, value: -56, to: today) ?? today
        var byWeekday: [Int: [TimeInterval]] = [:]
        var weekdayValues: [TimeInterval] = []
        for (day, seconds) in dailyWork where day >= historyStart && day < today && seconds > 0 {
            let weekday = calendar.component(.weekday, from: day)
            byWeekday[weekday, default: []].append(seconds)
            if (2...6).contains(weekday) { weekdayValues.append(seconds) }
        }
        func average(_ values: [TimeInterval]) -> TimeInterval { values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count) }
        // 최근 기록이 전혀 없으면 추세를 세울 수 없으니 월 소정근로시간(209h)을 예상으로 쓴다. 며칠 일한 값으로 월 전체를 줄이지 않는다.
        if byWeekday.isEmpty { return standardMonthlyHours * 3_600 }
        let weekdayAverage = average(weekdayValues)
        func expected(_ day: Date) -> TimeInterval {
            let weekday = calendar.component(.weekday, from: day)
            if let values = byWeekday[weekday], !values.isEmpty { return average(values) }
            return (2...6).contains(weekday) ? weekdayAverage : 0
        }
        var total: TimeInterval = 0
        var day = monthStart
        while day < monthEnd {
            let done = dailyWork[day] ?? 0
            if day < today { total += done }
            else if day == today { total += max(done, expected(day)) }
            else { total += expected(day) }
            day = calendar.date(byAdding: .day, value: 1, to: day) ?? monthEnd
        }
        return total
    }

    static func intervalTitle(_ seconds: Int, language: MapHomeLanguage) -> String {
        switch seconds {
        case ..<60: language.text("\(seconds)초", "\(seconds)s")
        case ..<3_600: language.text("\(seconds / 60)분", "\(seconds / 60) min")
        default: language.text("\(seconds / 3_600)시간", "\(seconds / 3_600) h")
        }
    }

    /// 그날 업무로 잡힌 구간들. 재생·지난 날짜는 이 구간에서 시각까지의 근무 시간만 센다(업무 밖에서는 늘지 않는다).
    static func workSpans(
        actuals: [ActualRecord],
        travel: [TravelSegment],
        stays: [PlaceStay],
        placeKinds: [String: FrequentPlaceKind],
        day: TimeSpan,
        asOf now: Date
    ) -> [TimeSpan] {
        DayPhaseEngine.completePhases(
            actuals: actuals.filter { let s = $0.span(asOf: now); return s.start < day.end && day.start < s.end },
            travel: travel.filter { $0.span.start < day.end && day.start < $0.span.end },
            stays: stays.filter { $0.span.start < day.end && day.start < $0.span.end },
            placeKinds: placeKinds,
            in: day,
            asOf: now
        )
        .filter { phase in
            DayPhaseEngine.categoryDurations([phase], scope: .canonical).contains { $0.categoryID == workKey && $0.actual > 0 }
        }
        .map(\.span)
    }

    static func workSeconds(in spans: [TimeSpan], until date: Date) -> TimeInterval {
        spans.reduce(0) { $0 + max(0, min($1.end, date).timeIntervalSince($1.start)) }
    }

    /// 표시 간격 단위로 내린 값(설정한 간격마다 한 번씩 오른다).
    static func quantized(_ seconds: TimeInterval, tick: TimeInterval) -> TimeInterval {
        let step = max(1, tick)
        return (seconds / step).rounded(.down) * step
    }

    static func earnings(workSeconds: TimeInterval, hourlyRate: Double) -> Double {
        max(0, workSeconds) / 3_600 * hourlyRate
    }

    /// 화면에 보일 오늘 근무 시간. 근무 중이면 마지막으로 센 뒤 흐른 시간을 표시 간격 단위로 더한다.
    static func liveWorkSeconds(base: TimeInterval, baseDate: Date, isWorking: Bool, now: Date, tick: TimeInterval) -> TimeInterval {
        guard isWorking else { return base }
        let elapsed = max(0, now.timeIntervalSince(baseDate))
        let step = max(1, tick)
        return base + (elapsed / step).rounded(.down) * step
    }

    /// 1분 사이 근무 시간이 30초 넘게 늘었으면 지금 근무 중으로 본다.
    static func isWorking(workNow: TimeInterval, workMinuteAgo: TimeInterval) -> Bool {
        workNow - workMinuteAgo > 30
    }

    struct MonthSummary: Equatable {
        var workSeconds: TimeInterval
        var commuteSeconds: TimeInterval
        var earnings: Double
        /// 출퇴근 시간까지 넣은 실질 시급. 출퇴근이 없으면 nil.
        var effectiveHourlyRate: Double?
    }

    /// 달 합계. 출퇴근은 근무한 날의 이동 시간으로 본다.
    static func monthSummary(totals: [Date: [String: TimeInterval]], hourlyRate: Double) -> MonthSummary {
        var work: TimeInterval = 0, commute: TimeInterval = 0
        for values in totals.values {
            let dayWork = values[workKey] ?? 0
            guard dayWork > 0 else { continue }
            work += dayWork
            commute += values[movementKey] ?? 0
        }
        let pay = earnings(workSeconds: work, hourlyRate: hourlyRate)
        let effective: Double? = commute > 0 && work > 0 ? pay / ((work + commute) / 3_600) : nil
        return MonthSummary(workSeconds: work, commuteSeconds: commute, earnings: pay, effectiveHourlyRate: effective)
    }

    /// 지도 라벨·하루 요약이 쓰는 마지막 계산 결과.
    struct Live: Equatable {
        var todayWorkSeconds: TimeInterval
        var measuredAt: Date
        var isWorking: Bool
        var hourlyRate: Double
        var month: MonthSummary?
        var showsNet: Bool
        /// 추세로 예측한 이번 달 총 근무 시간(시급 산정 기준).
        var projectedMonthWorkSeconds: TimeInterval
        /// 수당 모델로 본 이번 달 예상 월급(보여 줄 기준).
        var expectedMonthPay: Double
        /// 지난 석 달 근무 시간(월 키 → 초). 설정 화면의 월급 기록 입력에 보여 준다.
        var pastMonthWorkSeconds: [String: TimeInterval] = [:]
    }

    /// 영어 설정이면 USD, 한국어 설정이면 원으로 표시한다.
    static func wonText(_ value: Double, language: MapHomeLanguage = .current) -> String {
        let number = Int(value.rounded()).formatted(.number.locale(Locale(identifier: "en_US")).grouping(.automatic))
        return language == .english ? "\(number) USD" : "\(number)원"
    }
}

/// 연봉 카운터 설정: 연봉(세전/세후)·월급·이번 달 누적 금액·누적 시급·간격별 금액. 값은 이 기기에만 저장한다.
struct MapHomeSalarySettingsSheet: View {
    let language: MapHomeLanguage
    /// 이번 달 지금까지 잡힌 근무 시간(초)과 추세로 예측한 이번 달 총 근무 시간.
    let monthWorkSeconds: TimeInterval
    let projectedMonthWorkSeconds: TimeInterval
    /// 지난 석 달 근무 시간(월 키 → 초).
    var pastMonthWorkSeconds: [String: TimeInterval] = [:]
    @AppStorage(MapHomeSalaryPolicy.annualKey) private var annualPay = 0.0
    @AppStorage(MapHomeSalaryPolicy.isNetInputKey) private var isNetInput = false
    @AppStorage(MapHomeSalaryPolicy.monthlyPayKey) private var monthlyPay = 0.0
    @AppStorage(MapHomeSalaryPolicy.showsNetKey) private var showsNet = true
    @AppStorage(MapHomeSalaryPolicy.isHourlyKey) private var isHourly = false
    @AppStorage(MapHomeSalaryPolicy.hourlyKey) private var hourlyPay = 0.0
    @AppStorage(MapHomeSalaryPolicy.hourlyTaxKey) private var hourlyTaxRaw = MapHomeSalaryPolicy.HourlyTax.threePointThree.rawValue
    @AppStorage(MapHomeSalaryPolicy.weeklyHolidayKey) private var weeklyHoliday = false
    @AppStorage(MapHomeSalaryPolicy.hourlyIsNetKey) private var hourlyIsNet = false
    @AppStorage(MapHomeSalaryPolicy.monthAccumKey) private var monthAccum = 0.0
    @AppStorage(MapHomeSalaryPolicy.monthAccumMonthKey) private var monthAccumMonth = ""
    @AppStorage(MapHomeSalaryPolicy.tickKey) private var tickSeconds = 10
    @AppStorage(MapHomeSalaryPolicy.payHistoryKey) private var payHistoryRaw = ""
    @State private var payTexts: [String: String] = [:]
    @State private var annualText = ""
    @State private var monthlyText = ""
    @State private var hourlyText = ""
    @State private var accumText = ""

    private var settings: MapHomeSalaryPolicy.Settings {
        MapHomeSalaryPolicy.Settings(
            annualPay: annualPay,
            isNetInput: isNetInput,
            monthlyPay: monthlyPay,
            showsNet: showsNet,
            monthAccumOverride: monthAccumMonth == MapHomeSalaryPolicy.monthKey(.now) ? monthAccum : 0,
            payHistory: MapHomeSalaryPolicy.decodePayHistory(payHistoryRaw),
            isHourly: isHourly,
            hourly: hourlyPay,
            hourlyTax: MapHomeSalaryPolicy.HourlyTax(rawValue: hourlyTaxRaw) ?? .threePointThree,
            includesWeeklyHoliday: weeklyHoliday,
            hourlyIsNet: hourlyIsNet
        )
    }

    /// 연봉 또는 시급 중 하나를 고른다.
    private enum InputKind: Hashable { case annual, hourly }

    private var inputKind: Binding<InputKind> {
        Binding(
            get: { isHourly ? .hourly : .annual },
            set: { isHourly = $0 == .hourly }
        )
    }

    /// 지난 석 달의 월 키(최근 달부터).
    private var pastMonthKeys: [String] {
        (1...3).compactMap { offset in
            MapHomeGrowthPolicy.localCalendar.date(byAdding: .month, value: -offset, to: .now).map { MapHomeSalaryPolicy.monthKey($0) }
        }
    }

    private var paySamples: [MapHomeSalaryPolicy.PaySample] {
        MapHomeSalaryPolicy.paySamples(settings, pastMonthWorkSeconds: pastMonthWorkSeconds)
    }

    private func monthLabel(_ key: String) -> String {
        let parts = key.split(separator: "-")
        guard parts.count == 2, let month = Int(parts[1]) else { return key }
        return language.text("\(month)월", "\(parts[0])-\(parts[1])")
    }

    private func won(_ value: Double) -> String { MapHomeSalaryPolicy.wonText(value) }

    var body: some View {
        let settings = settings
        let samples = paySamples
        let rate = MapHomeSalaryPolicy.hourlyRate(settings, monthWorkSeconds: monthWorkSeconds, projectedMonthWorkSeconds: projectedMonthWorkSeconds, samples: samples)
        let model = MapHomeSalaryPolicy.fitPayModel(baseMonthly: MapHomeSalaryPolicy.inputMonthly(settings), samples: samples)
        let expectedPay = MapHomeSalaryPolicy.expectedMonthPay(settings, projectedMonthWorkSeconds: max(projectedMonthWorkSeconds, monthWorkSeconds), samples: samples)
        let basis = settings.showsNetAmounts ? language.text("세후", "net") : language.text("세전", "gross")
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(language.text("연봉 카운터", "Salary counter"))
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                Text(language.text(
                    "업무 시간에만 번 돈이 쌓여요. 금액은 이 기기에만 저장돼요.",
                    "Earnings grow only during work time. Stored only on this device."
                ))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.tpSecondary)

                // 1. 연봉 또는 시급. 세전/세후는 표시 기준 하나로 고르고, 입력은 세전·세후 어느 쪽이든 된다.
                card {
                    Picker("", selection: inputKind) {
                        Text(language.text("연봉", "Annual")).tag(InputKind.annual)
                        Text(language.text("시급", "Hourly")).tag(InputKind.hourly)
                    }
                    .pickerStyle(.segmented)
                    if isHourly {
                        let weekly = max(projectedMonthWorkSeconds, monthWorkSeconds) / 3_600 * 7 / 30.4
                        let hourlyGrossNow = hourlyText.isEmpty && hourlyPay <= 0
                            ? MapHomeSalaryPolicy.linkedHourlyGross(settings)
                            : MapHomeSalaryPolicy.hourlyGross(settings, weeklyHours: weekly)
                        field(language.text("세전 시급", "Gross hourly"), text: Binding(
                            get: { hourlyIsNet ? "" : hourlyText },
                            set: { hourlyText = $0 }
                        ), unit: language.text("원", "USD"), placeholder: String(Int(hourlyGrossNow.rounded()))) {
                            hourlyIsNet = false
                            hourlyPay = number(hourlyText)
                        }
                        field(language.text("세후 시급", "Net hourly"), text: Binding(
                            get: { hourlyIsNet ? hourlyText : "" },
                            set: { hourlyText = $0 }
                        ), unit: language.text("원", "USD"), placeholder: String(Int((hourlyGrossNow * settings.hourlyTax.keepRate).rounded()))) {
                            hourlyIsNet = true
                            hourlyPay = number(hourlyText)
                        }
                        Picker("", selection: $hourlyTaxRaw) {
                            Text(language.text("3.3% 공제", "3.3%")).tag(MapHomeSalaryPolicy.HourlyTax.threePointThree.rawValue)
                            Text(language.text("4대보험", "Insurance")).tag(MapHomeSalaryPolicy.HourlyTax.fourInsurance.rawValue)
                            Text(language.text("세금 없음", "None")).tag(MapHomeSalaryPolicy.HourlyTax.none.rawValue)
                        }
                        .pickerStyle(.segmented)
                        Toggle(language.text("주휴수당 포함(주 15시간 이상)", "Include weekly holiday pay"), isOn: $weeklyHoliday)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .tint(Color.tpAccent)
                        Text(language.text(
                            "시간 = 돈. 근무 시간이 늘면 금액도 같이 올라요. 입력하지 않은 쪽은 세금 방식으로 자동 계산해요.",
                            "Time = money. Earnings rise with work hours. The other field is computed from the tax method."
                        ))
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(Color.tpSecondary)
                    } else {
                        let grossWon = MapHomeSalaryPolicy.linkedAnnualGross(settings)
                        let netWon = MapHomeSalaryPolicy.netOfGross(grossWon)
                        field(language.text("세전 연봉", "Gross annual"), text: Binding(
                            get: { isNetInput ? "" : annualText },
                            set: { annualText = $0 }
                        ), unit: language.text("원", "USD"), placeholder: String(Int(grossWon.rounded()))) {
                            isNetInput = false
                            annualPay = number(annualText)
                            monthlyPay = 0
                        }
                        field(language.text("세후 연봉", "Net annual"), text: Binding(
                            get: { isNetInput ? annualText : "" },
                            set: { annualText = $0 }
                        ), unit: language.text("원", "USD"), placeholder: String(Int(netWon.rounded()))) {
                            isNetInput = true
                            annualPay = number(annualText)
                            monthlyPay = 0
                        }
                        field(language.text("월급", "Monthly pay"), text: $monthlyText, unit: language.text("원", "USD"),
                              placeholder: String(Int(MapHomeSalaryPolicy.inputMonthly(settings).rounded()))) {
                            annualPay = number(monthlyText) * 12
                            monthlyPay = 0
                            annualText = String(Int(annualPay.rounded()))
                        }
                        Text(language.text("연봉이나 월급 중 하나만 적으면 나머지는 자동 계산돼요(월급제면 월급만).", "Enter either annual or monthly; the other is computed."))
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(Color.tpSecondary)
                    }
                }

                // 1-1. 표시 기준: 세전 또는 세후
                card {
                    Picker("", selection: $showsNet) {
                        Text(language.text("세전", "Gross")).tag(false)
                        Text(language.text("세후", "Net")).tag(true)
                    }
                    .pickerStyle(.segmented)
                    Text(language.text("연봉·시급 모두 여기서 고른 기준으로 카운터와 누적 금액을 보여 줘요.", "Counter and totals use this basis for annual and hourly pay."))
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(Color.tpSecondary)
                }

                if !isHourly {
                // 2-1. 지난달 실제 받은 월급(수당 포함) → 수당 모델
                card {
                    Text(language.text("받은 월급 기록(실수령 세후, 수당 포함)", "Pay received (net, incl. overtime)"))
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                    ForEach(pastMonthKeys, id: \.self) { key in
                        let hours = (pastMonthWorkSeconds[key] ?? 0) / 3_600
                        HStack {
                            Text(monthLabel(key)).font(.system(size: 13, weight: .semibold, design: .rounded))
                            Text(language.text("근무 \(String(format: "%.0f", hours))시간", "\(String(format: "%.0f", hours)) h"))
                                .font(.system(size: 11)).foregroundStyle(Color.tpSecondary)
                            Spacer()
                            TextField(language.text("받은 금액", "Received"), text: Binding(
                                get: { grouped(payTexts[key] ?? "") },
                                set: { payTexts[key] = $0.filter(\.isNumber); savePayHistory() }
                            ))
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 130)
                            Text(language.text("원", "USD")).font(.system(size: 13))
                        }
                    }
                    Text(model.sampleCount == 0
                         ? language.text("기록이 없어 법정 기준(통상시급 × 1.5)으로 수당을 봐요. 받은 월급을 넣을수록 정확해져요.", "No records: overtime at 1.5× base. Add months to refine.")
                         : language.text(
                            "기록 \(model.sampleCount)개월로 맞춤: 고정 \(won(model.fixedMonthly)) + 209시간 초과 1시간당 \(won(model.overtimeHourly)).",
                            "Fitted from \(model.sampleCount) months: fixed \(won(model.fixedMonthly)) + \(won(model.overtimeHourly)) per hour over 209."
                         ))
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(Color.tpSecondary)
                    if let expectedPay {
                        row(language.text("이번 달 예상 월급(\(basis))", "Expected this month (\(basis))"), won(expectedPay), bold: true)
                    }
                }

                }

                // 3. 이번 달 누적 금액(고칠 수 있음)
                card {
                    let computed = MapHomeSalaryPolicy.earnings(workSeconds: monthWorkSeconds, hourlyRate: rate ?? 0)
                    field(language.text("이번 달 누적(\(basis))", "This month (\(basis))"), text: $accumText, unit: language.text("원", "USD"),
                          placeholder: String(Int(computed.rounded()))) {
                        monthAccum = number(accumText)
                        monthAccumMonth = MapHomeSalaryPolicy.monthKey(.now)
                    }
                    Text(language.text(
                        "근무 \(String(format: "%.1f", monthWorkSeconds / 3_600))시간 기준 계산값 \(won(computed)). 실제와 다르면 고쳐 주세요(비우면 계산값).",
                        "Computed \(won(computed)) for \(String(format: "%.1f", monthWorkSeconds / 3_600)) h. Edit if different."
                    ))
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(Color.tpSecondary)
                }

                // 4. 누적 시급(고칠 수 없음)
                card {
                    row(language.text("누적 시급(\(basis))", "Hourly (\(basis))"), rate.map(won) ?? "-", bold: true)
                    Text(language.text(
                        "이번 달 예상 월급 ÷ 예상 근무 \(String(format: "%.0f", max(projectedMonthWorkSeconds, monthWorkSeconds) / 3_600))시간(지금까지 \(String(format: "%.0f", monthWorkSeconds / 3_600))시간 + 최근 8주 요일별 추세). 야근이 늘면 수당도 같이 늘고, 월말엔 그 달 월급과 맞아요. 누적을 고쳤으면 누적 ÷ 근무 시간.",
                        "Expected pay ÷ projected \(String(format: "%.0f", max(projectedMonthWorkSeconds, monthWorkSeconds) / 3_600)) h (\(String(format: "%.0f", monthWorkSeconds / 3_600)) h so far + 8-week trend). Overtime raises both; exact at month end."
                    ))
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(Color.tpSecondary)
                }

                // 5. 간격별 금액
                Text(language.text("표시 간격", "Update every"))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Picker("", selection: $tickSeconds) {
                    ForEach(MapHomeSalaryPolicy.tickChoices, id: \.self) { seconds in
                        Text(MapHomeSalaryPolicy.intervalTitle(seconds, language: language)).tag(seconds)
                    }
                }
                .pickerStyle(.menu)
                if let rate {
                    card {
                        row(language.text("\(MapHomeSalaryPolicy.intervalTitle(tickSeconds, language: language))마다", "Every \(MapHomeSalaryPolicy.intervalTitle(tickSeconds, language: language))"),
                            won(rate / 3_600 * Double(tickSeconds)), bold: true)
                        row(language.text("초급", "Per second"), String(format: "%.1f원", rate / 3_600))
                        row(language.text("분급", "Per minute"), won(rate / 60))
                        row(language.text("시급", "Per hour"), won(rate))
                        row(language.text("일급(8시간)", "Per day (8 h)"), won(rate * 8))
                    }
                }

                if settings.isConfigured {
                    Button(language.text("연봉 카운터 끄기", "Turn off"), role: .destructive) {
                        annualPay = 0; monthlyPay = 0; monthAccum = 0
                        isHourly = false; hourlyPay = 0; hourlyIsNet = false
                        annualText = ""; hourlyText = ""; monthlyText = ""; accumText = ""
                    }
                }
            }
            .padding(22)
        }
        .background(Color.tpBackground)
        .onAppear {
            payTexts = settings.payHistory.mapValues { String(Int($0.rounded())) }
            annualText = annualPay > 0 ? String(Int(annualPay.rounded())) : ""
            monthlyText = monthlyPay > 0 ? String(Int(monthlyPay.rounded())) : ""
            hourlyText = hourlyPay > 0 ? String(Int(hourlyPay.rounded())) : ""
            accumText = settings.monthAccumOverride > 0 ? String(Int(settings.monthAccumOverride.rounded())) : ""
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) { content() }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.tpSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func row(_ title: String, _ value: String, bold: Bool = false) -> some View {
        HStack {
            Text(title).foregroundStyle(Color.tpSecondary)
            Spacer()
            Text(value).monospacedDigit().fontWeight(bold ? .bold : .medium)
        }
        .font(.system(size: bold ? 15 : 13, design: .rounded))
    }

    /// 입력은 바로 저장한다(따로 저장 버튼 없음).
    private func field(_ title: String, text: Binding<String>, unit: String, placeholder: String, onChange: @escaping () -> Void) -> some View {
        HStack {
            Text(title).font(.system(size: 13, weight: .semibold, design: .rounded))
            Spacer()
            TextField(grouped(placeholder), text: Binding(
                get: { grouped(text.wrappedValue) },
                set: { text.wrappedValue = $0.filter(\.isNumber) }
            ))
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.roundedBorder)
                .frame(width: 130)
                .onChange(of: text.wrappedValue) { _, _ in onChange() }
            Text(unit).font(.system(size: 13))
        }
    }

    private func number(_ text: String) -> Double { Double(text.filter(\.isNumber)) ?? 0 }

    private func grouped(_ text: String) -> String { MapHomeSalaryPolicy.grouped(text) }

    private func savePayHistory() {
        var history = settings.payHistory
        for (key, text) in payTexts { history[key] = number(text) }
        payHistoryRaw = MapHomeSalaryPolicy.encodePayHistory(history)
    }
}

// MARK: - 알림

/// 사용자가 받을 수 있는 알림 종류. 장소 도착·출발은 등록한 장소 기록으로, 기상은 수면 구간 종료로, 시급은 연봉 카운터로 만든다.
enum MapHomeAlarmKind: String, CaseIterable, Codable, Identifiable {
    case arriveCompany, leaveCompany
    case arriveSchool, leaveSchool
    case arriveAcademy, leaveAcademy
    case arriveHome, leaveHome
    case wakeUp
    case dailyCard
    case rateChange, breakEven

    var id: String { rawValue }

    enum Group: String, CaseIterable {
        case place, day, salary
        func title(_ language: MapHomeLanguage) -> String {
            switch self {
            case .place: language.text("장소", "Places")
            case .day: language.text("하루", "Day")
            case .salary: language.text("연봉 카운터", "Salary counter")
            }
        }
    }

    var group: Group {
        switch self {
        case .wakeUp, .dailyCard: .day
        case .rateChange, .breakEven: .salary
        default: .place
        }
    }

    func title(_ language: MapHomeLanguage) -> String {
        switch self {
        case .arriveCompany: language.text("출근했어요", "Arrived at work")
        case .leaveCompany: language.text("퇴근했어요", "Left work")
        case .arriveSchool: language.text("등교했어요", "Arrived at school")
        case .leaveSchool: language.text("하교했어요", "Left school")
        case .arriveAcademy: language.text("학원에 도착했어요", "Arrived at academy")
        case .leaveAcademy: language.text("학원에서 나왔어요", "Left academy")
        case .arriveHome: language.text("집에 왔어요", "Home")
        case .leaveHome: language.text("외출했어요", "Left home")
        case .wakeUp: language.text("일어났어요", "Woke up")
        case .dailyCard: language.text("자정 하루 요약 카드", "Midnight day card")
        case .rateChange: language.text("시급 변동(±3%)", "Hourly rate moved (±3%)")
        case .breakEven: language.text("퇴근 손익분기", "Overtime break-even")
        }
    }

    func detail(_ language: MapHomeLanguage) -> String {
        switch self {
        case .arriveCompany, .arriveSchool, .arriveAcademy, .arriveHome:
            language.text("등록한 장소에 머물기 시작하면 알려요.", "When a stay at the registered place begins.")
        case .leaveCompany, .leaveSchool, .leaveAcademy, .leaveHome:
            language.text("장소를 떠나 3분이 지나면 알려요.", "Three minutes after leaving the place.")
        case .wakeUp: language.text("수면 구간이 끝나면 알려요(하루 한 번).", "When the sleep span ends (once a day).")
        case .dailyCard: language.text("자정 5분 뒤 어제 카드를 보고 저장·공유할 수 있어요.", "At 00:05 open yesterday's card to save or share.")
        case .rateChange: language.text("추정 시급이 3% 이상 움직이면 알려요(30분에 한 번).", "When the estimated rate moves 3%+ (max every 30 min).")
        case .breakEven: language.text("근무 중 1시간 안에 시급이 기준의 90% 아래로 내려가면 알려요.", "When another hour of work would push the rate below 90% of base.")
        }
    }

    var systemImage: String {
        switch self {
        case .arriveCompany, .leaveCompany: "briefcase.fill"
        case .arriveSchool, .leaveSchool: "graduationcap.fill"
        case .arriveAcademy, .leaveAcademy: "book.fill"
        case .arriveHome, .leaveHome: "house.fill"
        case .wakeUp: "sunrise.fill"
        case .dailyCard: "photo.on.rectangle.angled"
        case .rateChange: "chart.line.uptrend.xyaxis"
        case .breakEven: "clock.badge.exclamationmark"
        }
    }

    /// 장소 종류별 도착·출발 알림.
    static func arrive(_ kind: FrequentPlaceKind) -> MapHomeAlarmKind? {
        switch kind {
        case .company: .arriveCompany
        case .school: .arriveSchool
        case .academy: .arriveAcademy
        case .home: .arriveHome
        default: nil
        }
    }

    static func leave(_ kind: FrequentPlaceKind) -> MapHomeAlarmKind? {
        switch kind {
        case .company: .leaveCompany
        case .school: .leaveSchool
        case .academy: .leaveAcademy
        case .home: .leaveHome
        default: nil
        }
    }
}

struct MapHomeAlarmSettings: Equatable {
    static let storageKey = "mapHomeAlarmSettings"
    static let defaultEnabled: Set<MapHomeAlarmKind> = [.arriveCompany, .leaveCompany, .wakeUp, .dailyCard]
    var enabled: Set<MapHomeAlarmKind>

    init(enabled: Set<MapHomeAlarmKind> = MapHomeAlarmSettings.defaultEnabled) { self.enabled = enabled }

    init(rawValue: String) {
        let kinds = rawValue.data(using: .utf8).flatMap { try? JSONDecoder().decode([MapHomeAlarmKind].self, from: $0) }
        enabled = kinds.map(Set.init) ?? MapHomeAlarmSettings.defaultEnabled
    }

    var rawValue: String {
        (try? String(data: JSONEncoder().encode(enabled.map(\.rawValue).sorted().compactMap(MapHomeAlarmKind.init(rawValue:))), encoding: .utf8)) ?? "[]"
    }

    /// 하루 카드 알림 시각(기본 오전 8시). 사용자가 설정에서 바꾼다.
    static let dailyCardHourKey = "mapHomeDailyCardHour"
    static let dailyCardMinuteKey = "mapHomeDailyCardMinute"
    static var dailyCardTime: DateComponents {
        let defaults = UserDefaults.standard
        let hasValue = defaults.object(forKey: dailyCardHourKey) != nil
        return DateComponents(
            hour: hasValue ? defaults.integer(forKey: dailyCardHourKey) : 8,
            minute: defaults.integer(forKey: dailyCardMinuteKey)
        )
    }

    static var current: MapHomeAlarmSettings {
        UserDefaults.standard.object(forKey: storageKey) == nil
            ? MapHomeAlarmSettings()
            : MapHomeAlarmSettings(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "")
    }
}

/// 기록에서 알림 이벤트를 찾는 순수 규칙. 같은 이벤트는 `key`로 한 번만 보낸다.
enum MapHomeAlarmPolicy {
    struct Event: Equatable {
        var kind: MapHomeAlarmKind
        var key: String
        var date: Date
        var body: String
    }

    /// 최근 이 시간 안에 생긴 일만 알린다(앱이 늦게 깨어나 묵은 일을 쏟아내지 않게).
    static let recentWindow: TimeInterval = 45 * 60
    /// 떠난 뒤 이 시간은 기다린다(잠깐 나갔다 돌아오는 경우).
    static let leaveSettle: TimeInterval = 10 * 60

    static func hoursText(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        return minutes >= 60 ? "\(minutes / 60)시간 \(minutes % 60)분" : "\(minutes)분"
    }

    static func timeText(_ date: Date, language: MapHomeLanguage) -> String {
        date.formatted(Date.FormatStyle().hour().minute().locale(language.locale))
    }

    /// 등록지점 범위 판정으로 도착·출발 알림 이벤트를 만든다. 최근 45분 안에 확정된 것만 알린다.
    static func zoneEvents(
        readings: [SensorReading],
        frequentPlaces: [FrequentPlace],
        now: Date,
        language: MapHomeLanguage
    ) -> [Event] {
        var events: [Event] = []
        for place in frequentPlaces {
            guard let point = place.point,
                  let arriveKind = MapHomeAlarmKind.arrive(place.kind),
                  let leaveKind = MapHomeAlarmKind.leave(place.kind) else { continue }
            let samples: [MapHomePlaceZone.Sample] = readings.compactMap { reading in
                guard let here = reading.point else { return nil }
                return MapHomePlaceZone.Sample(
                    date: reading.timestamp,
                    distance: distanceMeters(here, point),
                    isMoving: reading.motion.isMovement
                )
            }
            let time = { (date: Date) in timeText(date, language: language) }
            for result in MapHomePlaceZone.events(samples: samples, radius: place.radiusMeters) {
                switch result {
                case .arrived(let date):
                    events.append(Event(
                        kind: arriveKind,
                        key: "\(arriveKind.rawValue)-z\(Int(date.timeIntervalSince1970 / 600))",
                        date: date,
                        body: language.text("\(time(date))에 \(place.name) 도착 확인", "Arrived at \(place.name) at \(time(date))")
                    ))
                case .departed(let date):
                    events.append(Event(
                        kind: leaveKind,
                        key: "\(leaveKind.rawValue)-z\(Int(date.timeIntervalSince1970 / 600))",
                        date: date,
                        body: language.text("\(time(date))에 \(place.name)에서 출발 확인", "Left \(place.name) at \(time(date))")
                    ))
                }
            }
        }
        return events.filter { $0.date > now - recentWindow && $0.date <= now }
    }

    /// 장소 도착·출발. 머문 기록이 다시 계산돼 id가 바뀌어도 같은 일이 되도록 키는 종류 + 10분 단위 시각으로 만든다.
    static func placeEvents(
        stays: [PlaceStay],
        placeKinds: [String: FrequentPlaceKind],
        now: Date,
        language: MapHomeLanguage
    ) -> [Event] {
        var events: [Event] = []
        let kinds: [(PlaceStay, FrequentPlaceKind)] = stays.compactMap { stay in placeKinds[stay.placeKey].map { (stay, $0) } }
        for (stay, kind) in kinds {
            let start = stay.span.start, end = stay.span.end
            if let arrive = MapHomeAlarmKind.arrive(kind), start > now - recentWindow, start <= now {
                events.append(Event(
                    kind: arrive, key: "\(arrive.rawValue)-\(Int(start.timeIntervalSince1970 / 600))", date: start,
                    body: language.text("\(timeText(start, language: language))에 \(stay.displayName) 도착", "Arrived at \(stay.displayName) at \(timeText(start, language: language))")
                ))
            }
            if let leave = MapHomeAlarmKind.leave(kind), end > now - recentWindow, end <= now - leaveSettle {
                // 같은 장소에 10분 안에 다시 머물기 시작했으면 떠난 게 아니다.
                let returned = kinds.contains { other, otherKind in
                    otherKind == kind && other.span.start > end && other.span.start <= end + 10 * 60
                }
                if !returned {
                    events.append(Event(
                        kind: leave, key: "\(leave.rawValue)-\(Int(end.timeIntervalSince1970 / 600))", date: end,
                        body: language.text("\(timeText(end, language: language))에 \(stay.displayName)에서 출발", "Left \(stay.displayName) at \(timeText(end, language: language))")
                    ))
                }
            }
        }
        return events
    }

    /// 기상: 오늘 수면 구간이 끝났고 그 뒤로 수면이 없을 때(하루 한 번).
    static func wakeEvent(phases: [DayPhaseSpan], now: Date, calendar: Calendar, language: MapHomeLanguage) -> Event? {
        let sleeps = phases.filter { $0.phase == .sleep }.sorted { $0.span.end < $1.span.end }
        guard let last = sleeps.last, last.span.end > now - recentWindow, last.span.end <= now - 2 * 60 else { return nil }
        let dayKey = MapHomeSalaryPolicy.monthKey(now, calendar: calendar) + String(format: "-%02d", calendar.component(.day, from: now))
        let slept = last.span.duration / 3_600
        return Event(
            kind: .wakeUp, key: "wake-\(dayKey)", date: last.span.end,
            body: language.text(
                "\(timeText(last.span.end, language: language)) 기상 · \(String(format: "%.1f", slept))시간 잤어요",
                "Up at \(timeText(last.span.end, language: language)) · slept \(String(format: "%.1f", slept)) h"
            )
        )
    }

    /// 시급이 마지막으로 알린 값에서 3% 이상 움직였을 때.
    static func rateChangeEvent(previous: Double?, current: Double, now: Date, language: MapHomeLanguage) -> Event? {
        guard let previous, previous > 0 else { return nil }
        let change = (current - previous) / previous
        guard abs(change) >= 0.03 else { return nil }
        let arrow = change > 0 ? "▲" : "▼"
        return Event(
            kind: .rateChange, key: "rate-\(Int(now.timeIntervalSince1970 / 1_800))", date: now,
            body: language.text(
                "\(arrow) \(MapHomeSalaryPolicy.wonText(previous)) → \(MapHomeSalaryPolicy.wonText(current)) (\(String(format: "%+.1f", change * 100))%)",
                "\(arrow) \(MapHomeSalaryPolicy.wonText(previous)) → \(MapHomeSalaryPolicy.wonText(current)) (\(String(format: "%+.1f", change * 100))%)"
            )
        )
    }

    /// 지금부터 몇 시간 더 일하면 시급이 기준(월급 ÷ 209h)의 90% 아래로 내려가는지. 8시간 안에 안 내려가면 nil.
    static func breakEvenHours(
        settings: MapHomeSalaryPolicy.Settings,
        monthWorkSeconds: TimeInterval,
        projectedMonthWorkSeconds: TimeInterval,
        samples: [MapHomeSalaryPolicy.PaySample]
    ) -> Double? {
        guard let base = MapHomeSalaryPolicy.baseHourlyRate(settings) else { return nil }
        let floor = base * 0.9
        var hours = 0.0
        while hours <= 8 {
            let extra = hours * 3_600
            if let rate = MapHomeSalaryPolicy.hourlyRate(
                settings, monthWorkSeconds: monthWorkSeconds + extra,
                projectedMonthWorkSeconds: projectedMonthWorkSeconds + extra, samples: samples
            ), rate < floor {
                return hours
            }
            hours += 0.5
        }
        return nil
    }
}

/// 알림을 실제로 보내고, 보낸 이벤트 키를 기억해 중복을 막는다. 앱이 켜져 있을 때와 백그라운드 새로 고침 때 모두 쓴다.
@MainActor
final class MapHomeAlarmCenter {
    static let shared = MapHomeAlarmCenter()
    static let deliveredKey = "mapHomeAlarmDelivered"
    static let lastRateKey = "mapHomeAlarmLastRate"
    static let dailyCardIdentifier = "taption-alarm-dailyCard"
    static let userInfoKind = "taptionAlarm"
    static let userInfoDay = "taptionAlarmDay"
    static let userInfoAt = "taptionAlarmAt"

    private var delivered: [String: Double] = {
        (UserDefaults.standard.dictionary(forKey: MapHomeAlarmCenter.deliveredKey) as? [String: Double]) ?? [:]
    }()

    func isAuthorized() async -> Bool {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        return status == .authorized || status == .provisional || status == .ephemeral
    }

    func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    /// 장소·기상 이벤트를 찾아 켜 둔 것만 보낸다.
    func evaluate(
        actuals: [ActualRecord],
        travel: [TravelSegment],
        stays: [PlaceStay],
        frequentPlaces: [FrequentPlace],
        readings: [SensorReading] = [],
        now: Date = .now,
        language: MapHomeLanguage = .current
    ) async {
        let settings = MapHomeAlarmSettings.current
        guard !settings.enabled.isDisjoint(with: Set(MapHomeAlarmKind.allCases.filter { $0.group != .salary && $0 != .dailyCard })) else { return }
        let placeKinds = FrequentPlaceResolutionEngine().kindsByPlaceKey(frequentPlaces)
        var events = MapHomeAlarmPolicy.placeEvents(stays: stays, placeKinds: placeKinds, now: now, language: language)
        // 등록지점 범위(히스테리시스)로 도착·출발을 다시 판정한다: 들어와서 머무르고, 나가서 움직여야 확정.
        // 측정이 없는 장소는 위의 머묾 기록 판정을 그대로 쓴다.
        let zoneKinds = Set(frequentPlaces.filter { $0.point != nil }.map(\.kind))
        if !readings.isEmpty, !zoneKinds.isEmpty {
            let zoneAlarmKinds = Set(zoneKinds.flatMap { kind in
                [MapHomeAlarmKind.arrive(kind), MapHomeAlarmKind.leave(kind)].compactMap { $0 }
            })
            events = events.filter { !zoneAlarmKinds.contains($0.kind) }
            events += MapHomeAlarmPolicy.zoneEvents(readings: readings, frequentPlaces: frequentPlaces, now: now, language: language)
        }
        if settings.enabled.contains(.wakeUp) {
            let calendar = MapHomeGrowthPolicy.localCalendar
            let dayStart = calendar.startOfDay(for: now)
            let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? now
            let phases = DayPhaseEngine.completePhases(
                actuals: actuals, travel: travel, stays: stays, placeKinds: placeKinds,
                in: TimeSpan(start: dayStart, end: dayEnd), asOf: now
            )
            if let wake = MapHomeAlarmPolicy.wakeEvent(phases: phases, now: now, calendar: calendar, language: language) {
                events.append(wake)
            }
        }
        for event in events where settings.enabled.contains(event.kind) {
            await deliver(event, language: language)
        }
        prune(now: now)
    }

    /// 연봉 카운터가 시급을 다시 계산할 때 부른다.
    func noteRate(_ rate: Double, isWorking: Bool, breakEvenHours: Double?, now: Date = .now, language: MapHomeLanguage = .current) async {
        let settings = MapHomeAlarmSettings.current
        let previous = UserDefaults.standard.object(forKey: Self.lastRateKey) as? Double
        if settings.enabled.contains(.rateChange),
           let event = MapHomeAlarmPolicy.rateChangeEvent(previous: previous, current: rate, now: now, language: language) {
            if await deliver(event, language: language) { UserDefaults.standard.set(rate, forKey: Self.lastRateKey) }
        } else if previous == nil {
            UserDefaults.standard.set(rate, forKey: Self.lastRateKey)
        }
        if settings.enabled.contains(.breakEven), isWorking, let hours = breakEvenHours, hours <= 1 {
            let calendar = MapHomeGrowthPolicy.localCalendar
            let dayKey = MapHomeSalaryPolicy.monthKey(now, calendar: calendar) + String(format: "-%02d", calendar.component(.day, from: now))
            let event = MapHomeAlarmPolicy.Event(
                kind: .breakEven, key: "breakEven-\(dayKey)", date: now,
                body: hours <= 0
                    ? language.text("지금 시급이 기준의 90% 아래예요. 더 일할수록 시급이 내려가요.", "Your rate is already under 90% of base; more hours lower it further.")
                    : language.text("\(String(format: "%.1f", hours))시간 더 일하면 시급이 기준의 90% 아래로 내려가요.", "\(String(format: "%.1f", hours)) more hours push your rate under 90% of base.")
            )
            _ = await deliver(event, language: language)
        }
    }

    /// 하루 카드 알림(매일 반복, 기본 오전 8시). 꺼지면 예약을 지운다.
    func syncDailyCardSchedule(language: MapHomeLanguage = .current) async {
        let center = UNUserNotificationCenter.current()
        guard MapHomeAlarmSettings.current.enabled.contains(.dailyCard), await isAuthorized() else {
            center.removePendingNotificationRequests(withIdentifiers: [Self.dailyCardIdentifier])
            return
        }
        let content = UNMutableNotificationContent()
        content.title = language.text("어제 하루 카드가 준비됐어요", "Yesterday's card is ready")
        content.body = language.text("눌러서 보고 저장하거나 공유하세요.", "Tap to view, save or share.")
        content.sound = .default
        content.userInfo = [Self.userInfoKind: MapHomeAlarmKind.dailyCard.rawValue]
        var components = DateComponents()
        let time = MapHomeAlarmSettings.dailyCardTime
        components.hour = time.hour
        components.minute = time.minute
        try? await center.add(UNNotificationRequest(
            identifier: Self.dailyCardIdentifier, content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        ))
    }

    @discardableResult
    private func deliver(_ event: MapHomeAlarmPolicy.Event, language: MapHomeLanguage) async -> Bool {
        guard delivered[event.key] == nil, await isAuthorized() else { return false }
        let content = UNMutableNotificationContent()
        content.title = event.kind.title(language)
        content.body = event.body
        content.sound = .default
        content.userInfo = [Self.userInfoKind: event.kind.rawValue, Self.userInfoAt: event.date.timeIntervalSince1970]
        do {
            try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "taption-alarm-\(event.key)", content: content, trigger: nil))
        } catch {
            return false
        }
        delivered[event.key] = event.date.timeIntervalSince1970
        UserDefaults.standard.set(delivered, forKey: Self.deliveredKey)
        TaptionPlanDiagnosticsLogger.shared.record("alarm_delivered", fields: ["kind": event.kind.rawValue])
        return true
    }

    private func prune(now: Date) {
        let cutoff = now.timeIntervalSince1970 - 3 * 86_400
        let kept = delivered.filter { $0.value >= cutoff }
        if kept.count != delivered.count {
            delivered = kept
            UserDefaults.standard.set(delivered, forKey: Self.deliveredKey)
        }
    }
}

/// 알림 설정: 종류별 켜고 끄기, 권한 상태.
struct MapHomeAlarmSettingsSheet: View {
    let language: MapHomeLanguage
    @AppStorage(MapHomeAlarmSettings.storageKey) private var raw = MapHomeAlarmSettings().rawValue
    @AppStorage(MapHomeAlarmSettings.dailyCardHourKey) private var cardHour = 8
    @AppStorage(MapHomeAlarmSettings.dailyCardMinuteKey) private var cardMinute = 0
    @State private var isAuthorized: Bool?

    private var settings: MapHomeAlarmSettings { MapHomeAlarmSettings(rawValue: raw) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(language.text("알림", "Alerts"))
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                Text(language.text(
                    "앱이 기록을 갱신할 때(켜져 있을 때·iOS가 허용한 백그라운드 새로 고침) 찾은 일을 알려요. 위치 '항상 허용'이 있어야 앱이 꺼져 있어도 받을 수 있어요.",
                    "Sent when the app refreshes its records (foreground or iOS-allowed background refresh). 'Always' location access lets alerts arrive while closed."
                ))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.tpSecondary)

                if isAuthorized == false {
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    } label: {
                        Label(language.text("알림 권한이 꺼져 있어요 · 설정 열기", "Notifications are off · Open Settings"), systemImage: "bell.slash.fill")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.tpHoliday)
                    }
                }

                ForEach(MapHomeAlarmKind.Group.allCases, id: \.self) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(group.title(language))
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.tpSecondary)
                        VStack(spacing: 0) {
                            ForEach(MapHomeAlarmKind.allCases.filter { $0.group == group }) { kind in
                                Toggle(isOn: binding(kind)) {
                                    HStack(spacing: 10) {
                                        Image(systemName: kind.systemImage)
                                            .foregroundStyle(Color.tpAccent)
                                            .frame(width: 22)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(kind.title(language)).font(.system(size: 14, weight: .semibold, design: .rounded))
                                            Text(kind.detail(language)).font(.system(size: 11)).foregroundStyle(Color.tpSecondary)
                                        }
                                    }
                                }
                                .tint(Color.tpAccent)
                                .padding(.vertical, 8)
                            }
                        }
                        .padding(.horizontal, 14)
                        .background(Color.tpSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    if group == .day {
                        HStack {
                            Text(language.text("하루 카드 알림 시각", "Day card time"))
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                            Spacer()
                            DatePicker("", selection: cardTimeBinding, displayedComponents: .hourAndMinute)
                                .labelsHidden()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.tpSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
            }
            .padding(22)
        }
        .background(Color.tpBackground)
        .task { isAuthorized = await MapHomeAlarmCenter.shared.isAuthorized() }
    }

    private var cardTimeBinding: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(bySettingHour: cardHour, minute: cardMinute, second: 0, of: .now) ?? .now
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                cardHour = parts.hour ?? 8
                cardMinute = parts.minute ?? 0
                Task { await MapHomeAlarmCenter.shared.syncDailyCardSchedule(language: language) }
            }
        )
    }

    private func binding(_ kind: MapHomeAlarmKind) -> Binding<Bool> {
        Binding(
            get: { settings.enabled.contains(kind) },
            set: { on in
                var next = settings
                if on { next.enabled.insert(kind) } else { next.enabled.remove(kind) }
                raw = next.rawValue
                Task {
                    if on, await !MapHomeAlarmCenter.shared.isAuthorized() {
                        isAuthorized = await MapHomeAlarmCenter.shared.requestAuthorization()
                    }
                    await MapHomeAlarmCenter.shared.syncDailyCardSchedule(language: language)
                }
            }
        )
    }
}

// MARK: - 하루 카드

/// 인스타그램에 올리기 좋은 1080×1080 하루 요약 카드의 데이터.
struct MapHomeDailyCardData: Equatable {
    var dateText: String
    var weekdayText: String
    var earnedText: String?
    var workText: String?
    var steps: Int?
    var distanceText: String?
    var categories: [MapHomeDaySummaryEntry]
    var totalText: String
    var accessoryID: String?
    var memoText: String? = nil
    var routePoints: [GeoPoint] = []
    /// 사용자가 골라 넣은 항목(최대 4개). 비어 있으면 기본 통계를 쓴다.
    var metrics: [MapHomeCardMetric] = []
}

/// 하루 카드에 올릴 달력 항목 하나.
extension MapHomeDailyCardData {
    /// 값을 불러오기 전 자리표시자.
    static var placeholder: MapHomeDailyCardData {
        MapHomeDailyCardData(
            dateText: "", weekdayText: "", earnedText: nil, workText: nil,
            steps: nil, distanceText: nil, categories: [], totalText: "", accessoryID: nil
        )
    }
}

struct MapHomeCardMetric: Identifiable, Equatable {
    let id: String
    let title: String
    let systemImage: String
    let value: String
}

/// 공유 카드에 올릴 항목 고르기: 최대 4개, 골라 둔 순서를 기억한다.
enum MapHomeCardMetricSelection {
    static let storageKey = "mapHomeDailyCardMetrics"
    static let maximum = 4

    static func load() -> [String] {
        guard let data = UserDefaults.standard.string(forKey: storageKey)?.data(using: .utf8),
              let ids = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Array(ids.prefix(maximum))
    }

    static func save(_ ids: [String]) {
        let trimmed = Array(ids.prefix(maximum))
        let data = (try? JSONEncoder().encode(trimmed)) ?? Data("[]".utf8)
        UserDefaults.standard.set(String(decoding: data, as: UTF8.self), forKey: storageKey)
    }

    /// 항목 id에 해당하는 값을 카드용 문자열로 바꾼다.
    static func value(for kind: MapHomeCalendarTimeKind, number: Double) -> String {
        if kind.isCount { return MapHomeCalendarTimeTotalsPolicy.countCellText(count: number) }
        if kind.isDistance { return MapHomeCalendarTimeTotalsPolicy.distanceCellText(meters: number) }
        return MapHomeCalendarTimeTotalsPolicy.cellText(seconds: number)
    }
}

/// 540×540pt로 그려 2배로 렌더링하면 1080×1080이 된다.
struct MapHomeDailyCardView: View {
    static let side: CGFloat = 540
    let data: MapHomeDailyCardData
    let language: MapHomeLanguage
    /// 배경으로 깐 지도(경로 포함). 위에 밝은 막을 씌워 디밍한다.
    var mapImage: UIImage?

    var body: some View {
        ZStack {
            if let mapImage {
                Image(uiImage: mapImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: Self.side, height: Self.side)
                    .clipped()
                Color.tpBackground.opacity(0.72)
            } else {
                LinearGradient(colors: [Color.tpBackground, Color.tpSurface], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(data.dateText).font(.system(size: 34, weight: .bold, design: .rounded))
                        Text(data.weekdayText).font(.system(size: 18, weight: .semibold, design: .rounded)).foregroundStyle(Color.tpSecondary)
                    }
                    Spacer()
                    MapHomeStickmanMarker(action: .activity, equippedAccessoryID: data.accessoryID)
                        .frame(width: 96, height: 96)
                }
                if !data.metrics.isEmpty {
                    // 사용자가 고른 항목(최대 4개)을 카드 윗부분에 그대로 보여 준다.
                    HStack(spacing: 10) {
                        ForEach(data.metrics) { metric in
                            stat(metric.title, metric.value, metric.systemImage)
                        }
                    }
                } else {
                HStack(spacing: 12) {
                    if let earned = data.earnedText {
                        stat(language.text("오늘 번 돈", "Earned"), earned, "wonsign.circle.fill")
                    }
                    if let work = data.workText {
                        stat(language.text("근무", "Work"), work, "briefcase.fill")
                    }
                    if let steps = data.steps {
                        stat(language.text("걸음", "Steps"), steps.formatted(.number.grouping(.automatic)), "figure.walk")
                    }
                    if let memo = data.memoText {
                        stat(language.text("메모", "Memos"), memo, "note.text")
                    }
                    if let distance = data.distanceText {
                        stat(language.text("이동", "Travel"), distance, "point.topleft.down.to.point.bottomright.curvepath")
                    }
                }
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text(data.totalText).font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundStyle(Color.tpSecondary)
                    ForEach(data.categories.prefix(5)) { entry in
                        HStack(spacing: 10) {
                            Image(systemName: entry.systemImage).foregroundStyle(entry.tint).frame(width: 22)
                            Text(entry.title).font(.system(size: 16, weight: .semibold, design: .rounded)).frame(width: 90, alignment: .leading)
                            GeometryReader { proxy in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color.tpLine.opacity(0.5))
                                    Capsule().fill(entry.tint).frame(width: max(6, proxy.size.width * entry.ratio))
                                }
                            }
                            .frame(height: 12)
                            Text(MapHomeAlarmPolicy.hoursText(entry.seconds))
                                .font(.system(size: 14, weight: .semibold, design: .rounded)).monospacedDigit()
                                .frame(width: 96, alignment: .trailing)
                            Text("\(Int((entry.ratio * 100).rounded()))%").font(.system(size: 15, weight: .bold, design: .rounded)).monospacedDigit().frame(width: 46, alignment: .trailing)
                        }
                    }
                }
                Spacer(minLength: 0)
                HStack {
                    Text("BOKKI Plan").font(.system(size: 14, weight: .bold, design: .rounded)).foregroundStyle(Color.tpAccent)
                    Spacer()
                    Text(language.text("자동 기록으로 만든 하루", "A day from automatic records"))
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(Color.tpSecondary)
                }
            }
            .padding(36)
            .foregroundStyle(Color.tpInk)
        }
        .frame(width: Self.side, height: Self.side)
    }

    private func stat(_ title: String, _ value: String, _ symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.tpSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(value).font(.system(size: 20, weight: .bold, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.55), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// 카드 미리보기와 저장·공유.
struct MapHomeDailyCardSheet: View {
    /// 화면이 바뀔 때마다 다시 만들지 않도록, 시트가 열릴 때 한 번만 부른다.
    let makeData: () -> MapHomeDailyCardData
    let makeValues: () -> [String: Double]
    let language: MapHomeLanguage
    @State private var baseData: MapHomeDailyCardData?
    /// 하루 달력 값(항목 id → 값). 고르기 목록과 카드에 쓴다.
    @State private var dayValues: [String: Double] = [:]
    @State private var image: UIImage?
    @State private var mapImage: UIImage?
    @State private var shareURL: URL?
    @State private var message: String?
    @State private var selectedIDs: [String] = MapHomeCardMetricSelection.load()
    @State private var isPickerPresented = false

    private var data: MapHomeDailyCardData {
        var copy = baseData ?? .placeholder
        copy.metrics = selectedIDs.compactMap { id in
            guard let kind = MapHomeCalendarTimeKind(rawValue: id) else { return nil }
            return MapHomeCardMetric(
                id: id,
                title: kind.title(language),
                systemImage: kind.systemImage,
                value: MapHomeCardMetricSelection.value(for: kind, number: dayValues[id] ?? 0)
            )
        }
        return copy
    }

    private func toggle(_ id: String) {
        if let index = selectedIDs.firstIndex(of: id) {
            selectedIDs.remove(at: index)
        } else if selectedIDs.count < MapHomeCardMetricSelection.maximum {
            selectedIDs.append(id)
        }
        MapHomeCardMetricSelection.save(selectedIDs)
    }

    private var metricPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(language.text("공유할 항목 (최대 4개)", "Items to share (up to 4)"))
                .font(.system(size: 14, weight: .semibold, design: .rounded))
            HStack(spacing: 8) {
                ForEach(0..<MapHomeCardMetricSelection.maximum, id: \.self) { index in
                    slot(index)
                }
            }
            Button {
                isPickerPresented = true
            } label: {
                Label(language.text("항목 추가", "Add item"), systemImage: "plus.circle.fill")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .frame(maxWidth: .infinity, minHeight: 40)
            }
            .buttonStyle(.bordered)
            .tint(Color.tpAccent)
        }
        .padding(14)
        .background(Color.tpSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .sheet(isPresented: $isPickerPresented) {
            metricPicker
                .presentationDetents([.large])
        }
    }

    private func slot(_ index: Int) -> some View {
        let filled = index < selectedIDs.count ? MapHomeCalendarTimeKind(rawValue: selectedIDs[index]) : nil
        return Button {
            if let filled { toggle(filled.rawValue) } else { isPickerPresented = true }
        } label: {
            VStack(spacing: 4) {
                if let filled {
                    Image(systemName: filled.systemImage).foregroundStyle(Color.tpAccent)
                    Text(filled.title(language)).font(.system(size: 10, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.6)
                    Text(MapHomeCardMetricSelection.value(for: filled, number: dayValues[filled.rawValue] ?? 0))
                        .font(.system(size: 12, weight: .bold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.6)
                } else {
                    Image(systemName: "plus").font(.system(size: 16, weight: .bold)).foregroundStyle(Color.tpSecondary)
                }
            }
            .foregroundStyle(Color.tpInk)
            .frame(maxWidth: .infinity, minHeight: 74)
            .padding(.horizontal, 4)
            .background(filled == nil ? Color.clear : Color.tpBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.tpLine, style: StrokeStyle(lineWidth: 1, dash: filled == nil ? [5, 4] : []))
            }
        }
        .buttonStyle(.plain)
    }

    private var metricPicker: some View {
        NavigationStack {
            List {
                ForEach(MapHomeCalendarTimeKind.allCases) { kind in
                    let chosen = selectedIDs.contains(kind.rawValue)
                    let full = !chosen && selectedIDs.count >= MapHomeCardMetricSelection.maximum
                    Button {
                        toggle(kind.rawValue)
                    } label: {
                        HStack {
                            Image(systemName: kind.systemImage).foregroundStyle(Color.tpAccent).frame(width: 24)
                            Text(kind.title(language))
                            Spacer()
                            Text(MapHomeCardMetricSelection.value(for: kind, number: dayValues[kind.rawValue] ?? 0))
                                .foregroundStyle(Color.tpSecondary)
                            Image(systemName: chosen ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(chosen ? Color.tpAccent : Color.tpLine)
                        }
                    }
                    .disabled(full)
                }
            }
            .navigationTitle(language.text("공유 항목", "Share items"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(language.text("완료", "Done")) { isPickerPresented = false }
                }
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Text(language.text("하루 카드", "Day card"))
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .frame(maxWidth: .infinity, alignment: .leading)
                metricPanel
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
                } else {
                    ProgressView().frame(height: 300)
                }
                HStack(spacing: 12) {
                    Button { Task { await save() } } label: {
                        Label(language.text("사진에 저장", "Save to Photos"), systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    Button { share() } label: {
                        Label(language.text("공유", "Share"), systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.tpAccent)
                }
                .disabled(image == nil)
                if let message {
                    Text(message).font(.system(size: 13, weight: .medium)).foregroundStyle(Color.tpAccent)
                }
                Text(language.text("1080×1080 · 인스타그램 피드 크기", "1080×1080 · Instagram feed size"))
                    .font(.system(size: 12)).foregroundStyle(Color.tpSecondary)
            }
            .padding(22)
        }
        .background(Color.tpBackground)
        .task {
            // 열릴 때 한 번 불러온다. 이후에는 항목을 고를 때만 카드가 다시 그려진다.
            baseData = makeData()
            dayValues = makeValues()
        }
        // 지도는 경로가 바뀔 때만 다시 그리고, 카드 그림은 항목이 바뀔 때마다 새로 그린다.
        .task(id: baseData?.routePoints.count ?? -1) {
            mapImage = await Self.routeMap(points: baseData?.routePoints ?? [])
            image = Self.render(data: data, language: language, mapImage: mapImage)
        }
        .task(id: data) {
            image = Self.render(data: data, language: language, mapImage: mapImage)
        }
        .sheet(item: $shareURL) { url in MapHomeShareSheet(url: url) }
    }

    /// 경로가 가운데 오도록 지도를 그리고 경로선을 올린다. 경로가 없으면 nil(배경 없이 그라데이션).
    static func routeMap(points: [GeoPoint]) async -> UIImage? {
        let coordinates = points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        guard coordinates.count >= 2 else { return nil }
        let lats = coordinates.map(\.latitude), lons = coordinates.map(\.longitude)
        let center = CLLocationCoordinate2D(latitude: (lats.min()! + lats.max()!) / 2, longitude: (lons.min()! + lons.max()!) / 2)
        let span = MKCoordinateSpan(
            latitudeDelta: max(0.01, (lats.max()! - lats.min()!) * 1.5),
            longitudeDelta: max(0.01, (lons.max()! - lons.min()!) * 1.5)
        )
        let options = MKMapSnapshotter.Options()
        options.region = MKCoordinateRegion(center: center, span: span)
        options.size = CGSize(width: MapHomeDailyCardView.side, height: MapHomeDailyCardView.side)
        options.scale = 2
        guard let snapshot = try? await MKMapSnapshotter(options: options).start() else { return nil }
        let renderer = UIGraphicsImageRenderer(size: snapshot.image.size)
        return renderer.image { _ in
            snapshot.image.draw(at: .zero)
            let path = UIBezierPath()
            for (index, coordinate) in coordinates.enumerated() {
                let point = snapshot.point(for: coordinate)
                index == 0 ? path.move(to: point) : path.addLine(to: point)
            }
            path.lineWidth = 6
            path.lineJoinStyle = .round
            UIColor(Color.tpAccent).setStroke()
            path.stroke()
        }
    }

    @MainActor
    static func render(data: MapHomeDailyCardData, language: MapHomeLanguage, mapImage: UIImage?) -> UIImage? {
        let renderer = ImageRenderer(content: MapHomeDailyCardView(data: data, language: language, mapImage: mapImage))
        renderer.scale = 2
        renderer.proposedSize = ProposedViewSize(width: MapHomeDailyCardView.side, height: MapHomeDailyCardView.side)
        return renderer.uiImage
    }

    private func save() async {
        guard let image else { return }
        guard await MapHomeScreenRecordingStore.requestPhotoAddAccess() else {
            message = language.text("사진 저장 권한이 없어요. 설정에서 허용해 주세요.", "Photo access is needed to save.")
            return
        }
        let ok = await Self.saveImageToLibrary(image)
        message = ok ? language.text("사진 앱에 저장했어요.", "Saved to Photos.") : language.text("저장하지 못했어요.", "Could not save.")
    }

    /// 사진 앱에 저장한다. 사진 쪽 콜백은 메인 액터가 아니므로 이 함수는 액터 밖에서 돈다(메인에서 부르면 충돌).
    nonisolated static func saveImageToLibrary(_ image: UIImage) async -> Bool {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }, completionHandler: { success, _ in
                continuation.resume(returning: success)
            })
        }
    }

    private func share() {
        guard let image, let png = image.pngData() else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("BOKKI-Plan-\(data.dateText.filter(\.isNumber)).png")
        try? png.write(to: url)
        shareURL = url
    }
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}


/// 알람을 눌렀을 때 뜨는 확인 화면. 시간은 지금으로 채워져 있고 고칠 수 있다. 확인하면 실제 기록이 남는다.
struct MapHomeAlarmConfirmSheet: View {
    let kind: MapHomeAlarmKind
    let initialDate: Date
    let language: MapHomeLanguage
    let onConfirm: (Date) -> Void
    let onCancel: () -> Void
    @State private var at: Date

    init(kind: MapHomeAlarmKind, initialDate: Date, language: MapHomeLanguage, onConfirm: @escaping (Date) -> Void, onCancel: @escaping () -> Void) {
        self.kind = kind
        self.initialDate = initialDate
        self.language = language
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        _at = State(initialValue: initialDate)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(kind.title(language))
                .font(.system(size: 22, weight: .bold, design: .rounded))
            Text(language.text("시간을 확인하고 고쳐 주세요. 확인을 누르면 그 시각부터 기록돼요.", "Check the time and edit if needed. Recording starts from this time."))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.tpSecondary)
            DatePicker("", selection: $at, displayedComponents: [.date, .hourAndMinute])
                .datePickerStyle(.graphical)
                .labelsHidden()
            HStack(spacing: 12) {
                Button(language.text("취소", "Cancel"), action: onCancel)
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity, minHeight: 44)
                Button(language.text("확인", "Confirm")) { onConfirm(at) }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.tpAccent)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            Spacer(minLength: 0)
        }
        .padding(22)
        .background(Color.tpBackground)
    }
}

/// 알람 종류를 실제 기록 종류로 바꾼다. 집 도착·외출은 기록하지 않는다.
enum MapHomeAlarmRecordMapping {
    /// (기록 종류, 제목, 시작인지)
    static func entry(for kind: MapHomeAlarmKind, language: MapHomeLanguage) -> (categoryID: String, title: String, opens: Bool)? {
        switch kind {
        case .arriveCompany: ("work", language.text("업무", "Work"), true)
        case .leaveCompany: ("work", language.text("업무", "Work"), false)
        case .arriveSchool, .arriveAcademy: ("study", language.text("수업", "Class"), true)
        case .leaveSchool, .leaveAcademy: ("study", language.text("수업", "Class"), false)
        case .wakeUp: ("sleep", language.text("수면", "Sleep"), false)
        default: nil
        }
    }
}
