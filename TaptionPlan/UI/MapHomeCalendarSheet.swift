import CoreMotion
import SwiftUI

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
        pedometer.startUpdates(from: Date()) { data, _ in
            guard let data else { return }
            Task { @MainActor in steps = data.numberOfSteps.intValue }
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
    static let monthAccumKey = "mapHomeSalaryMonthAccum"
    static let monthAccumMonthKey = "mapHomeSalaryMonthAccumMonth"
    static let tickKey = "mapHomeSalaryTickSeconds"
    static let tickChoices = [1, 10, 30, 60, 300, 600, 1_800, 3_600]
    /// 주 40시간 기준 월 소정근로시간(주휴 포함).
    static let standardMonthlyHours = 209.0
    static let workKey = MapHomeCalendarTimeKind.work.rawValue
    static let movementKey = MapHomeCalendarTimeKind.movement.rawValue

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

        var isConfigured: Bool { annualPay > 0 || monthlyPay > 0 }
        var showsNetAmounts: Bool { isNetInput || showsNet }
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
            monthAccumOverride: override
        )
    }

    /// 입력 기준(세전 또는 세후)의 월급.
    static func inputMonthly(_ settings: Settings) -> Double {
        settings.monthlyPay > 0 ? settings.monthlyPay : settings.annualPay / 12
    }

    /// 보여 줄 기준의 월급. 세전 입력을 세후로 보면 4대보험·소득세를 뺀다.
    static func displayedMonthly(_ settings: Settings) -> Double {
        let input = inputMonthly(settings)
        return settings.isNetInput || !settings.showsNet ? input : MapHomeKoreanNetPay.monthly(gross: input).net
    }

    /// 월급 ÷ 209시간.
    static func baseHourlyRate(_ settings: Settings) -> Double? {
        let monthly = displayedMonthly(settings)
        return monthly > 0 ? monthly / standardMonthlyHours : nil
    }

    /// 이번 달 지금까지 번 돈. 직접 고친 값이 있으면 그 값.
    static func accumulated(_ settings: Settings, monthWorkSeconds: TimeInterval) -> Double {
        if settings.monthAccumOverride > 0 { return settings.monthAccumOverride }
        return earnings(workSeconds: monthWorkSeconds, hourlyRate: baseHourlyRate(settings) ?? 0)
    }

    /// 누적 시급: 이번 달 누적 금액 ÷ 이번 달 근무 시간. 근무가 1시간 미만이거나 누적을 고치지 않았으면 기본 시급.
    static func hourlyRate(_ settings: Settings, monthWorkSeconds: TimeInterval) -> Double? {
        guard let base = baseHourlyRate(settings) else { return nil }
        guard settings.monthAccumOverride > 0, monthWorkSeconds >= 3_600 else { return base }
        return settings.monthAccumOverride / (monthWorkSeconds / 3_600)
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
    }

    static func wonText(_ value: Double) -> String {
        "\(Int(value.rounded()).formatted(.number.grouping(.automatic)))원"
    }
}

/// 연봉 카운터 설정: 연봉(세전/세후)·월급·이번 달 누적 금액·누적 시급·간격별 금액. 값은 이 기기에만 저장한다.
struct MapHomeSalarySettingsSheet: View {
    let language: MapHomeLanguage
    /// 이번 달 지금까지 잡힌 근무 시간(초).
    let monthWorkSeconds: TimeInterval
    @AppStorage(MapHomeSalaryPolicy.annualKey) private var annualPay = 0.0
    @AppStorage(MapHomeSalaryPolicy.isNetInputKey) private var isNetInput = false
    @AppStorage(MapHomeSalaryPolicy.monthlyPayKey) private var monthlyPay = 0.0
    @AppStorage(MapHomeSalaryPolicy.showsNetKey) private var showsNet = true
    @AppStorage(MapHomeSalaryPolicy.monthAccumKey) private var monthAccum = 0.0
    @AppStorage(MapHomeSalaryPolicy.monthAccumMonthKey) private var monthAccumMonth = ""
    @AppStorage(MapHomeSalaryPolicy.tickKey) private var tickSeconds = 10
    @State private var annualManText = ""
    @State private var monthlyText = ""
    @State private var accumText = ""

    private var settings: MapHomeSalaryPolicy.Settings {
        MapHomeSalaryPolicy.Settings(
            annualPay: annualPay,
            isNetInput: isNetInput,
            monthlyPay: monthlyPay,
            showsNet: showsNet,
            monthAccumOverride: monthAccumMonth == MapHomeSalaryPolicy.monthKey(.now) ? monthAccum : 0
        )
    }

    private func won(_ value: Double) -> String { MapHomeSalaryPolicy.wonText(value) }

    var body: some View {
        let settings = settings
        let rate = MapHomeSalaryPolicy.hourlyRate(settings, monthWorkSeconds: monthWorkSeconds)
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

                // 1. 연봉과 세전/세후
                card {
                    Picker("", selection: $isNetInput) {
                        Text(language.text("세전 연봉", "Gross")).tag(false)
                        Text(language.text("세후 연봉", "Net")).tag(true)
                    }
                    .pickerStyle(.segmented)
                    field(language.text("연봉", "Annual pay"), text: $annualManText, unit: language.text("만원", "×10k"), placeholder: "4000") {
                        annualPay = number(annualManText) * 10_000
                    }
                    if !isNetInput {
                        Toggle(language.text("세후로 보기(4대보험·소득세 공제)", "Show after tax"), isOn: $showsNet)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .tint(Color.tpAccent)
                    }
                }

                // 2. 월급
                card {
                    field(language.text("월급", "Monthly pay"), text: $monthlyText, unit: language.text("원", "KRW"),
                          placeholder: String(Int(MapHomeSalaryPolicy.inputMonthly(MapHomeSalaryPolicy.Settings(annualPay: annualPay)).rounded()))) {
                        monthlyPay = number(monthlyText)
                    }
                    Text(language.text("비워 두면 연봉 ÷ 12. 상여·연장수당이 있으면 받은 월급으로 고쳐 주세요.", "Blank = annual ÷ 12."))
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(Color.tpSecondary)
                    if !isNetInput, MapHomeSalaryPolicy.inputMonthly(settings) > 0 {
                        let b = MapHomeKoreanNetPay.monthly(gross: MapHomeSalaryPolicy.inputMonthly(settings))
                        VStack(alignment: .leading, spacing: 3) {
                            row(language.text("세후 월급(추정)", "Net (est.)"), won(b.net), bold: true)
                            row(language.text("국민연금·건강·장기요양·고용", "Insurance"), "−" + won(b.pension + b.health + b.care + b.employment))
                            row(language.text("소득세·지방소득세", "Income tax"), "−" + won(b.incomeTax + b.localTax))
                        }
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                    }
                }

                // 3. 이번 달 누적 금액(고칠 수 있음)
                card {
                    let computed = MapHomeSalaryPolicy.earnings(workSeconds: monthWorkSeconds, hourlyRate: MapHomeSalaryPolicy.baseHourlyRate(settings) ?? 0)
                    field(language.text("이번 달 누적(\(basis))", "This month (\(basis))"), text: $accumText, unit: language.text("원", "KRW"),
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
                    Text(language.text("이번 달 누적 금액 ÷ 근무 시간. 누적을 고치지 않았으면 월급 ÷ 209시간.", "This month's total ÷ work hours, or monthly ÷ 209 h."))
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
                        annualManText = ""; monthlyText = ""; accumText = ""
                    }
                }
            }
            .padding(22)
        }
        .background(Color.tpBackground)
        .onAppear {
            annualManText = annualPay > 0 ? String(Int((annualPay / 10_000).rounded())) : ""
            monthlyText = monthlyPay > 0 ? String(Int(monthlyPay.rounded())) : ""
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
            TextField(placeholder, text: text)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.roundedBorder)
                .frame(width: 130)
                .onChange(of: text.wrappedValue) { _, _ in onChange() }
            Text(unit).font(.system(size: 13))
        }
    }

    private func number(_ text: String) -> Double { Double(text.filter(\.isNumber)) ?? 0 }
}
