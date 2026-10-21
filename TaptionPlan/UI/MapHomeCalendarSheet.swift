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
    case steps, photos, walkDistance, carDistance, transitDistance, awayTime

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
        case .carDistance: "car.fill"
        case .transitDistance: "tram.fill"
        case .awayTime: "door.left.hand.open"
        }
    }

    /// 시간 합계는 초, 이동거리는 미터로 같은 딕셔너리에 담는다.
    var isDistance: Bool {
        self == .distance || self == .walkDistance || self == .carDistance || self == .transitDistance
    }

    /// 방문 장소 수·이동 횟수·걸음 수·사진 수는 개수를 같은 딕셔너리에 담는다.
    var isCount: Bool { self == .places || self == .trips || self == .steps || self == .photos }

    /// 기본으로 늘 보이는 지표와, 사용자가 "+"로 더하는 지표.
    static let coreKinds: [MapHomeCalendarTimeKind] = [.sleep, .movement, .study, .work, .exercise, .hobby, .distance, .places, .trips]
    static let extraKinds: [MapHomeCalendarTimeKind] = [.steps, .photos, .walkDistance, .carDistance, .transitDistance, .awayTime]
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
    @State private var totals: [Date: [String: TimeInterval]] = [:]

    init(
        selectedDate: Binding<Date>,
        holidayName: @escaping (Date) -> String?,
        logStatuses: @escaping (Date) async -> [Date: MapHomeCalendarLogStatus] = { _ in [:] },
        timeTotals: @escaping (Date) async -> [Date: [String: TimeInterval]] = { _ in [:] },
        timeTint: @escaping (String) -> Color = { _ in Color.tpAccent },
        language: MapHomeLanguage = .korean
    ) {
        self._selectedDate = selectedDate
        self.holidayName = holidayName
        self.logStatuses = logStatuses
        self.timeTotals = timeTotals
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
        // 이번 달을 보고 있으면 걸음·기록 시간 같은 값을 30초마다 다시 읽어 달력에 바로 반영한다(깜빡임 없이 값만 교체).
        .task(id: displayedMonth) {
            let calendar = MapHomeGrowthPolicy.localCalendar
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled, calendar.isDate(displayedMonth, equalTo: .now, toGranularity: .month) else { continue }
                let month = displayedMonth
                let monthStatuses = await logStatuses(month)
                let value = await timeTotals(month)
                guard !Task.isCancelled, month == displayedMonth else { return }
                statuses = monthStatuses
                totals = value
            }
        }
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
