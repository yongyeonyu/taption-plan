import CoreMotion
import MapKit
import Photos
import SwiftUI
import UserNotifications

struct MapHomeCalendarSheet: View {
    /// 시트가 올라오는 시간. 그동안은 달 계산을 시작하지 않는다(SHT1102A01).
    private static let riseDuration: TimeInterval = 0.45

    @Binding private var selectedDate: Date
    private let holidayName: (Date) -> String?
    private let logStatuses: (Date) async -> [Date: MapHomeCalendarLogStatus]
    private let timeTotals: (Date) async -> [Date: [String: TimeInterval]]
    private let placeVisits: (Date) async -> [MapHomeCalendarPlaceVisit]
    private let timeTint: (String) -> Color
    private let language: MapHomeLanguage
    private let calendar: Calendar

    @State private var displayedMonth: Date
    @State private var statuses: [Date: MapHomeCalendarLogStatus] = [:]
    @Environment(\.displayScale) private var displayScale
    @AppStorage(MapHomeCalendarTimeKind.extraStorageKey) private var extraKindsRaw = ""
    @State private var selectedKind: MapHomeCalendarTimeKind?
    @State private var contentHeight: CGFloat
    @State private var measuredHeight: CGFloat = 0
    @State private var isSettled = false
    @State private var openedAt = ProcessInfo.processInfo.systemUptime
    /// 새 센서 기록이 들어올 때마다 바뀌는 값. 바뀌면 이번 달 지표를 바로 다시 읽는다.
    private let liveToken: Double
    private let liveTotals: (Date) async -> [Date: [String: TimeInterval]]
    @State private var totals: [Date: [String: TimeInterval]]
    @State private var visits: [MapHomeCalendarPlaceVisit] = []
    /// 켜면 지표 칩과 큰 숫자를 고른 날이 아니라 이번 달 하루 평균으로 보여 준다.
    @State private var showsMonthAverage = false
    @Environment(\.mapHomeWidePanelColumns) private var panelColumns

    @MainActor
    init(
        selectedDate: Binding<Date>,
        holidayName: @escaping (Date) -> String?,
        logStatuses: @escaping (Date) async -> [Date: MapHomeCalendarLogStatus] = { _ in [:] },
        timeTotals: @escaping (Date) async -> [Date: [String: TimeInterval]] = { _ in [:] },
        liveTotals: (@escaping (Date) async -> [Date: [String: TimeInterval]]) = { _ in [:] },
        placeVisits: @escaping (Date) async -> [MapHomeCalendarPlaceVisit] = { _ in [] },
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
        self.placeVisits = placeVisits
        self.timeTint = timeTint
        self.language = language

        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = language.locale
        calendar.timeZone = .current
        calendar.firstWeekday = 1
        self.calendar = calendar

        let day = calendar.startOfDay(for: selectedDate.wrappedValue)
        let month = calendar.date(from: calendar.dateComponents([.year, .month], from: day)) ?? day
        self._displayedMonth = State(initialValue: month)
        self._statuses = State(initialValue: MapHomeCalendarMonthMemory.shared.statuses(for: month))
        self._totals = State(initialValue: MapHomeCalendarMonthMemory.shared.totals(for: month))
        self._contentHeight = State(initialValue: MapHomeCalendarMonthMemory.shared.contentHeight)
    }

    @ViewBuilder
    private var monthSection: some View {
        header
            .padding(.horizontal, 20)
            .padding(.top, 18)

        weekdayHeader
            .padding(.horizontal, 16)
            .padding(.top, 18)

        monthGrid
            .padding(.horizontal, 16)
            .padding(.top, 8)
            // 좌우로 쓸면 다음 달/지난 달. 날짜 탭과 세로 스크롤은 그대로 둔다.
            .simultaneousGesture(
                DragGesture(minimumDistance: 24)
                    .onEnded { value in
                        let dx = value.translation.width, dy = value.translation.height
                        guard abs(dx) > 50, abs(dx) > abs(dy) * 1.5 else { return }
                        withAnimation(.easeInOut(duration: 0.2)) { shiftMonth(by: dx < 0 ? 1 : -1) }
                    }
            )
    }

    private var caloriesNote: String {
        let day = calendar.startOfDay(for: selectedDate)
        return totals[day]?[MapHomeCalendarTimeKind.caloriesEstimatedKey] == 1
            ? language.text(
                "이 날은 건강 앱 값이 없어 걸음 수와 몸무게로 추정했어요. 몸무게가 없으면 65kg로 계산해요.",
                "No Health data for this day, so this is estimated from steps and weight (65 kg if no weight is set)."
            )
            : language.text("건강 앱의 활동 에너지예요.", "Active energy from the Health app.")
    }

    @ViewBuilder
    private var summarySection: some View {
        timeMenu
            .padding(.horizontal, 16)
            .padding(.top, 12)

        if let selectedKind {
            timePanel(for: selectedKind)
                .padding(.horizontal, 16)
                .padding(.top, 12)
            if selectedKind == .calories {
                Text(caloriesNote)
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .medium))
                    .foregroundStyle(Color.tpSecondary)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
            }
            if selectedKind == .places {
                placeVisitList
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
            }
        }
    }

    var body: some View {
        ScrollView {
            MapHomeWidePanelColumns(columns: panelColumns) { monthSection } trailing: { summarySection }
            .padding(.bottom, 12)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                guard abs(height - measuredHeight) >= 0.5 else { return }
                measuredHeight = height
                MapHomeCalendarMonthMemory.shared.contentHeight = height
                // 올라오는 도중에 높이 목록을 바꾸면 시트 레이아웃을 다시 잰다.
                if isSettled { contentHeight = height }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.tpBackground)
        // 추가한 지표까지 내용에 딱 맞춰 연다. 화면보다 길면 스크롤로 이어진다.
        .presentationDetents(contentHeight > 0 ? [.height(contentHeight), .large] : [.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color.tpBackground)
        .task {
            try? await Task.sleep(for: .milliseconds(450))
            isSettled = true
            if measuredHeight > 0 { contentHeight = measuredHeight }
        }
        // 달이 바뀔 때뿐 아니라 "+"로 지표를 켜고 끌 때도 다시 읽는다(걸음·사진은 켠 때만 읽기 때문).
        .task(id: "\(selectedKind == .places)|\(selectedDate.timeIntervalSince1970)") {
            guard selectedKind == .places else { visits = []; return }
            let day = calendar.startOfDay(for: selectedDate)
            let value = await placeVisits(day)
            guard !Task.isCancelled else { return }
            visits = value
        }
        // 달을 넘기면 계절 테마도 그 달로 바꾸고, 닫으면 고른 날짜로 돌아온다(SEA1103A01).
        .onChange(of: displayedMonth) { _, month in
            TaptionSeasonStore.select(calendar.date(byAdding: .day, value: 14, to: month) ?? month)
        }
        .onDisappear { TaptionSeasonStore.select(selectedDate) }
        .task(id: "\(displayedMonth.timeIntervalSince1970)|\(extraKindsRaw)") {
            let month = displayedMonth
            let rememberedStatuses = MapHomeCalendarMonthMemory.shared.statuses(for: month)
            let rememberedTotals = MapHomeCalendarMonthMemory.shared.totals(for: month)
            if statuses != rememberedStatuses { statuses = rememberedStatuses }
            if totals != rememberedTotals { totals = rememberedTotals }
            let remaining = Self.riseDuration - (ProcessInfo.processInfo.systemUptime - openedAt)
            if remaining > 0 { try? await Task.sleep(for: .seconds(remaining)) }
            guard !Task.isCancelled else { return }
            let monthStatuses = await logStatuses(month)
            guard !Task.isCancelled, month == displayedMonth else { return }
            MapHomeCalendarMonthMemory.shared.store(statuses: monthStatuses, for: month)
            if statuses != monthStatuses { statuses = monthStatuses }
            let value = await timeTotals(month)
            guard !Task.isCancelled, month == displayedMonth else { return }
            MapHomeCalendarMonthMemory.shared.store(totals: value, for: month)
            if totals != value { totals = value }
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
                MapHomeCalendarTimeKind.steps, .distance, .walkDistance, .carDistance, .transitDistance, .stepDistance, .calories,
            ].reduce(into: [MapHomeCalendarTimeKind.caloriesEstimatedKey]) { $0.insert($1.rawValue) }
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
                MapHomeCalendarMonthMemory.shared.store(statuses: monthStatuses, for: month)
                MapHomeCalendarMonthMemory.shared.store(totals: value, for: month)
                if statuses != monthStatuses { statuses = monthStatuses }
                if totals != value { totals = value }
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

    /// 보고 있는 달의 하루 평균(오늘까지 지난 날 기준).
    private func monthAverage(of kind: MapHomeCalendarTimeKind) -> TimeInterval {
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: displayedMonth)) ?? displayedMonth
        let count = calendar.range(of: .day, in: .month, for: monthStart)?.count ?? 30
        let days = (0..<count).compactMap { calendar.date(byAdding: .day, value: $0, to: monthStart) }.filter { $0 <= Date.now }
        guard !days.isEmpty else { return 0 }
        return days.reduce(0) { $0 + seconds(of: kind, on: $1) } / Double(days.count)
    }

    private func chipSeconds(of kind: MapHomeCalendarTimeKind) -> TimeInterval {
        showsMonthAverage ? monthAverage(of: kind) : seconds(of: kind, on: selectedDate)
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
                    VStack(spacing: 1) {
                        HStack(spacing: 4) {
                            TaptionCuteIcon(kind.systemImage, size: 18)
                            Text(kind.title(language))
                                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        Text(MapHomeCalendarChipValue.text(kind: kind, value: chipSeconds(of: kind), language: language) ?? "–")
                            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .semibold))
                            .foregroundStyle(Color.tpSecondary)
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
            monthAverageToggle
        }
    }

    /// "+ 추가" 오른쪽 칸: 누르면 지표를 한 달 평균으로 본다.
    private var monthAverageToggle: some View {
        Button {
            showsMonthAverage.toggle()
        } label: {
            HStack(spacing: 5) {
                TaptionCuteIcon("chart.bar.xaxis", size: 16)
                Text(language.text("한달 평균", "Month avg"))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(showsMonthAverage ? Color.tpAccent : Color.tpSecondary)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(showsMonthAverage ? Color.tpAccent.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(showsMonthAverage ? Color.tpAccent : Color.tpLine, lineWidth: showsMonthAverage ? 1.2 : 0.8)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(language.text("한달 평균 보기", "Show month average"))
        .accessibilityAddTraits(showsMonthAverage ? .isSelected : [])
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
                TaptionCuteIcon("plus", size: 16)
                Text(language.text("추가", "Add"))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .semibold))
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
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(15)), weight: .bold))
                    .foregroundStyle(Color.tpInk)
                Spacer()
                if showsMonthAverage {
                    Text(language.text("\(calendar.component(.month, from: monthStart))월 하루 평균", "Monthly daily average"))
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .medium))
                        .foregroundStyle(Color.tpSecondary)
                } else if selectedInMonth {
                    Text(language.runtimeText("\(calendar.component(.month, from: selected))월 \(calendar.component(.day, from: selected))일",
                                       selected.formatted(Date.FormatStyle().month(.abbreviated).day().locale(language.locale))))
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .medium))
                        .foregroundStyle(Color.tpSecondary)
                }
            }
            Text(panelText(showsMonthAverage ? sum / Double(elapsedDays) : (selectedInMonth ? seconds(of: kind, on: selected) : 0), for: kind))
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(26)), weight: .bold))
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

    /// 고른 날 방문한 곳(10분 이상, 30 m 안은 한 곳). 달력 시트 전체 스크롤에 이어 내려가며 본다.
    private var placeVisitList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(language.text("방문한 곳 (10분 이상 · 30m 이내는 한 곳)", "Visited (10+ min, within 30 m merged)"))
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .semibold))
                .foregroundStyle(Color.tpSecondary)
                .padding(.bottom, 8)
            if visits.isEmpty {
                Text(language.text("조건에 맞는 방문 장소가 없어요", "No places match"))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .medium))
                    .foregroundStyle(Color.tpSecondary)
                    .padding(.vertical, 8)
            }
            ForEach(visits) { visit in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    TaptionCuteIcon(visit.systemImage ?? "mappin.circle.fill", size: 20)
                        .foregroundStyle(Color.tpAccent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(visit.name)
                            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(14)), weight: .semibold))
                            .foregroundStyle(Color.tpInk)
                        if let building = visit.buildingName, !building.isEmpty, building != visit.name {
                            Text(building)
                                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .medium))
                                .foregroundStyle(Color.tpSecondary)
                        }
                        Text("\(visit.arrival.formatted(date: .omitted, time: .shortened)) – \(visit.departure.formatted(date: .omitted, time: .shortened))"
                             + (visit.visitCount > 1 ? language.text(" · \(visit.visitCount)번", " · \(visit.visitCount)x") : ""))
                            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .medium))
                            .foregroundStyle(Color.tpSecondary)
                    }
                    Spacer(minLength: 8)
                    Text(Self.durationText(visit.seconds, language: language))
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .bold))
                        .foregroundStyle(Color.tpInk)
                }
                .padding(.vertical, 8)
                Divider()
            }
        }
        .padding(12)
        .background(Color.tpSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.tpLine.opacity(0.9), lineWidth: 0.8) }
    }

    private static func durationText(_ seconds: TimeInterval, language: MapHomeLanguage) -> String {
        let minutes = Int(seconds / 60)
        if minutes >= 60 {
            let h = minutes / 60, m = minutes % 60
            return language.text(m == 0 ? "\(h)시간" : "\(h)시간 \(m)분", m == 0 ? "\(h)h" : "\(h)h \(m)m")
        }
        return language.text("\(minutes)분", "\(minutes)m")
    }

    private func timeStat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .medium)).foregroundStyle(Color.tpSecondary)
            Text(value).font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(14)), weight: .bold)).foregroundStyle(Color.tpInk)
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
                    .font(.system(size: TaptionType.scaled(TaptionType.snapped(15)), weight: .semibold))
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
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(19)), weight: .bold))
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
                    .font(.system(size: TaptionType.scaled(TaptionType.snapped(15)), weight: .semibold))
                    .foregroundStyle(Color.tpInk)
                    .frame(width: 34, height: 34)
                    .background(Color.tpBackground, in: Circle())
            }
            .accessibilityLabel(language.text("다음 달", "Next month"))
        }
    }

    private var weekdayHeader: some View {
        let weekdays = language.weekdayHeaderSymbols
        return LazyVGrid(columns: gridColumns, spacing: 0) {
            ForEach(Array(weekdays.enumerated()), id: \.offset) { index, weekday in
                Text(weekday)
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(10)), weight: .semibold))
                    .foregroundStyle(weekdayColor(index: index))
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var monthGrid: some View {
        // 칸마다 달력 계산을 되풀이하지 않게 한 번만 구한다(SHT1102A01).
        let selectedDay = calendar.startOfDay(for: selectedDate)
        let today = calendar.startOfDay(for: .now)
        return LazyVGrid(columns: gridColumns, spacing: 7) {
            ForEach(monthDays, id: \.self) { date in
                if let date {
                    dayCell(for: date, selectedDay: selectedDay, today: today)
                } else {
                    Color.clear
                        .frame(maxWidth: .infinity, minHeight: 38)
                }
            }
        }
    }

    private func dayCell(for date: Date, selectedDay: Date, today: Date) -> some View {
        let info = MapHomeCalendarMonthMemory.shared.dayInfo(for: date, in: displayedMonth) {
            .init(
                day: calendar.component(.day, from: date),
                weekday: calendar.component(.weekday, from: date),
                holiday: holidayName(date)
            )
        }
        let day = info.day
        let weekday = info.weekday
        let holiday = info.holiday
        let isSelected = date == selectedDay
        let isToday = date == today
        let status = statuses[date]

        return Button {
            selectedDate = date
        } label: {
            VStack(spacing: 2) {
                Text(String(day))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(15)), weight: isSelected ? .bold : .regular))
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
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(10)), weight: .semibold))
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
        MapHomeCalendarMonthMemory.shared.days(for: displayedMonth) { makeMonthDays() }
    }

    private func makeMonthDays() -> [Date?] {
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
        MapHomeCalendarMonthMemory.shared.title(for: displayedMonth, key: language.monthTitleFormat) {
            let formatter = DateFormatter()
            formatter.locale = language.locale
            formatter.calendar = calendar
            formatter.dateFormat = language.monthTitleFormat
            return formatter.string(from: displayedMonth)
        }
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
        var title = language.text("\(monthTitle) \(day)일", "\(monthTitle) \(day)")
        if let holiday { title += ", \(holiday)" }
        switch status {
        case .incomplete: title += language.text(", 미확인 활동 있음", ", unconfirmed activity")
        case .complete: title += language.text(", 기록 완료", ", fully logged")
        case nil: break
        }
        return title
    }
}

// MARK: - 알림

// MARK: - 하루 카드
