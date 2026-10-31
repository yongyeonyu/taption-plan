import SwiftUI

/// 화랑이 머리 위 카운터 창에서 누른 줄. 누르면 그 카운터의 상세 화면이 올라온다.
enum MapHomeCounterDetailTarget: Hashable, Identifiable {
    case kind(MapHomeCounterKind)
    case salary

    var id: String {
        switch self {
        case .kind(let kind): kind.rawValue
        case .salary: "salary"
        }
    }
}

/// 상세 화면이 그리는 값. 계산은 `MapHomeCounterDetailBuilder`가 하고 화면은 글자와 비율만 받는다.
struct MapHomeCounterDetailContent: Equatable {
    struct Row: Equatable, Identifiable {
        let id: Int
        let title: String
        let subtitle: String?
        let value: String
        /// 같은 목록 안에서 이 줄이 차지하는 비율(0...1). 있으면 줄 아래에 막대로 보여 준다.
        var share: Double? = nil
    }

    struct Section: Equatable, Identifiable {
        let id: Int
        let title: String
        let rows: [Row]
    }

    let systemImage: String
    let title: String
    let value: String
    let sections: [Section]
    /// 합계와 목록이 어긋나는 이유처럼 읽는 사람이 알아야 하는 한 줄.
    let note: String?
    /// 값 아래 한 줄 요약(기록 건수 등).
    var caption: String? = nil
    /// 시간대별 막대 그래프 값(0시부터 24칸). 비어 있으면 그래프를 그리지 않는다.
    var hourly: [Double] = []
}

/// 카운터 상세 계산. 원본(센서 측정값·이동 구간·활동 기록·근무 구간)은 건드리지 않고 읽기만 한다.
enum MapHomeCounterDetailBuilder {
    /// 합계와 목록의 차이가 이 값(초) 미만이면 '그 밖의 자동 집계' 줄을 만들지 않는다.
    static let remainderThresholdSeconds: TimeInterval = 60

    /// 창 안에서 누른 높이로 몇 번째 줄인지 고른다. 줄은 위에서 아래로 같은 높이로 쌓여 있다.
    static func rowIndex(tapY: CGFloat, frame: CGRect, count: Int) -> Int? {
        guard count > 0, frame.height > 0, tapY.isFinite else { return nil }
        let fraction = (tapY - frame.minY) / frame.height
        return min(max(Int(fraction * CGFloat(count)), 0), count - 1)
    }

    static func timeText(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    static func spanText(_ start: Date, _ end: Date) -> String {
        "\(timeText(start)) – \(timeText(end))"
    }

    /// 걸음: 시간대별로 그 한 시간에 늘어난 걸음 수. 센서 값은 하루 누적이라 시간대 끝 값에서 시작 값을 뺀다.
    static func steps(
        readings: [SensorReading],
        total: String,
        dayStart: Date,
        language: MapHomeLanguage
    ) -> MapHomeCounterDetailContent {
        let calendar = Calendar.autoupdatingCurrent
        let counted = readings
            .compactMap { reading in reading.stepCount.map { (reading.timestamp, $0) } }
            .filter { $0.1 > 0 }
            .sorted { $0.0 < $1.0 }
        func cumulative(upTo limit: Date) -> Int {
            counted.last(where: { $0.0 <= limit })?.1 ?? 0
        }
        var deltas = [Int](repeating: 0, count: 24)
        for hour in 0..<24 {
            guard let start = calendar.date(byAdding: .hour, value: hour, to: dayStart),
                  let end = calendar.date(byAdding: .hour, value: hour + 1, to: dayStart) else { continue }
            deltas[hour] = max(0, cumulative(upTo: end) - cumulative(upTo: start))
        }
        let peak = Double(deltas.max() ?? 0)
        var rows: [MapHomeCounterDetailContent.Row] = []
        for hour in 0..<24 where deltas[hour] > 0 {
            guard let start = calendar.date(byAdding: .hour, value: hour, to: dayStart),
                  let end = calendar.date(byAdding: .hour, value: hour + 1, to: dayStart) else { continue }
            rows.append(.init(
                id: hour,
                title: spanText(start, end),
                subtitle: nil,
                value: language.text("\(deltas[hour].formatted())걸음", "\(deltas[hour].formatted()) steps"),
                share: peak > 0 ? Double(deltas[hour]) / peak : nil
            ))
        }
        return MapHomeCounterDetailContent(
            systemImage: MapHomeCounterKind.steps.systemImage,
            title: MapHomeCounterKind.steps.badgeTitle(language),
            value: total,
            sections: rows.isEmpty ? [] : [.init(id: 0, title: language.text("시간대별", "By hour"), rows: rows)],
            note: rows.isEmpty ? language.text("이 날 걸음 기록이 없습니다.", "No step records for this day.") : nil,
            caption: rows.isEmpty ? nil : language.text("걸음이 잡힌 시간대 \(rows.count)곳", "\(rows.count) active hours"),
            hourly: peak > 0 ? deltas.map { Double($0) / peak } : []
        )
    }

    /// 이동 거리: 수단별 합계와 이동 구간 목록.
    static func distance(
        segments: [TravelSegment],
        total: String,
        language: MapHomeLanguage
    ) -> MapHomeCounterDetailContent {
        let entries = MapHomeDayTravelSummary.entries(from: segments)
        let totalMeters = entries.reduce(0) { $0 + $1.meters }
        let modes = entries.enumerated().map { index, entry in
            MapHomeCounterDetailContent.Row(
                id: index,
                title: language.text(entry.mode.summaryKoreanTitle, entry.mode.summaryEnglishTitle),
                subtitle: nil,
                value: MapHomeDayTravelSummary.distanceText(entry.meters),
                share: totalMeters > 0 ? entry.meters / totalMeters : nil
            )
        }
        let trips = segments
            .filter { $0.distanceMeters.isFinite && $0.distanceMeters >= MapHomeDayTravelSummary.minimumMeters }
            .sorted { $0.span.start < $1.span.start }
        let longest = trips.map(\.distanceMeters).max() ?? 0
        let legs = trips.enumerated().map { index, segment in
            MapHomeCounterDetailContent.Row(
                id: index,
                title: spanText(segment.span.start, segment.span.end),
                subtitle: language.text(segment.mode.summaryKoreanTitle, segment.mode.summaryEnglishTitle),
                value: MapHomeDayTravelSummary.distanceText(segment.distanceMeters),
                share: longest > 0 ? segment.distanceMeters / longest : nil
            )
        }
        var sections: [MapHomeCounterDetailContent.Section] = []
        if !modes.isEmpty { sections.append(.init(id: 0, title: language.text("수단별", "By mode"), rows: modes)) }
        if !legs.isEmpty { sections.append(.init(id: 1, title: language.text("이동 구간", "Trips"), rows: legs)) }
        return MapHomeCounterDetailContent(
            systemImage: MapHomeCounterKind.distance.systemImage,
            title: MapHomeCounterKind.distance.badgeTitle(language),
            value: total,
            sections: sections,
            note: sections.isEmpty ? language.text("이 날 이동 기록이 없습니다.", "No trips for this day.") : nil,
            caption: legs.isEmpty ? nil : language.text("이동 \(legs.count)회", "\(legs.count) trips")
        )
    }

    /// 시간 카운터(업무·학습·취미·운동): 그 대분류로 기록된 활동 목록. 장소 체류에서 센 시간은
    /// 합계에만 들어 있으므로 목록과의 차이를 '그 밖의 자동 집계' 줄로 보여 준다.
    static func time(
        kind: MapHomeCounterKind,
        actuals: [ActualRecord],
        totalSeconds: TimeInterval,
        total: String,
        dayStart: Date,
        dayEnd: Date,
        now: Date,
        language: MapHomeLanguage
    ) -> MapHomeCounterDetailContent {
        let categoryID = kind.categoryID
        var items: [(title: String, subtitle: String?, seconds: TimeInterval)] = []
        let records = actuals
            .filter { $0.categoryID == categoryID }
            .sorted { $0.startedAt < $1.startedAt }
        for record in records {
            let start = max(record.startedAt, dayStart)
            let end = min(record.endedAt ?? min(now, dayEnd), dayEnd)
            guard end > start else { continue }
            items.append((record.title, spanText(start, end), end.timeIntervalSince(start)))
        }
        let listed = items.reduce(0) { $0 + $1.seconds }
        let recordCount = items.count
        let remainder = totalSeconds - listed
        if remainder >= remainderThresholdSeconds {
            items.append((
                language.text("그 밖의 자동 집계", "Other automatic time"),
                language.text("장소 체류 등", "Place stays and similar"),
                remainder
            ))
        }
        let denominator = max(totalSeconds, listed)
        let rows = items.enumerated().map { index, item in
            MapHomeCounterDetailContent.Row(
                id: index,
                title: item.title,
                subtitle: item.subtitle,
                value: DurationText.localized(item.seconds, english: language == .english),
                share: denominator > 0 ? item.seconds / denominator : nil
            )
        }
        return MapHomeCounterDetailContent(
            systemImage: kind.systemImage,
            title: kind.badgeTitle(language),
            value: total,
            sections: rows.isEmpty ? [] : [.init(id: 0, title: language.text("기록", "Records"), rows: rows)],
            note: rows.isEmpty ? language.text("이 날 기록된 시간이 없습니다.", "No time recorded for this day.") : nil,
            caption: recordCount == 0 ? nil : language.text("활동 \(recordCount)건", "\(recordCount) records")
        )
    }

    /// 번 돈: 근무 구간 목록과 시급.
    static func salary(
        spans: [TimeSpan],
        earned: String,
        hourlyRateText: String,
        language: MapHomeLanguage
    ) -> MapHomeCounterDetailContent {
        let valid = spans
            .filter { $0.end > $0.start }
            .sorted { $0.start < $1.start }
        let longest = valid.map(\.duration).max() ?? 0
        let rows = valid.enumerated().map { index, span in
            MapHomeCounterDetailContent.Row(
                id: index,
                title: spanText(span.start, span.end),
                subtitle: nil,
                value: DurationText.localized(span.duration, english: language == .english),
                share: longest > 0 ? span.duration / longest : nil
            )
        }
        var sections: [MapHomeCounterDetailContent.Section] = [
            .init(id: 0, title: language.text("시급", "Hourly rate"), rows: [
                .init(id: 0, title: hourlyRateText, subtitle: nil, value: "")
            ])
        ]
        if !rows.isEmpty { sections.append(.init(id: 1, title: language.text("근무 구간", "Work spans"), rows: rows)) }
        return MapHomeCounterDetailContent(
            systemImage: MapHomeCounterSalary.symbol(language: language),
            title: language.text("번 돈", "Earned"),
            value: earned,
            sections: sections,
            note: rows.isEmpty ? language.text("이 날 근무로 센 시간이 없습니다.", "No work time counted for this day.") : nil,
            caption: rows.isEmpty ? nil : language.text("근무 구간 \(rows.count)개", "\(rows.count) work spans")
        )
    }
}

/// 카운터 창을 눌렀을 때 올라오는 상세 화면.
///
/// 위에는 창에 보이는 카운터를 탭으로 늘어놓고, 아래에는 고른 카운터의 상세를 보여 준다.
/// 좌우로 밀어도 카운터가 넘어가며, 누른 줄의 탭이 처음에 골라져 열린다.
struct MapHomeCounterDetailSheet: View {
    let contents: [MapHomeCounterDetailContent]
    /// 보고 있는 날짜 글자(예: 10월 31일 토요일).
    let dateText: String

    @State private var selected: Int

    init(contents: [MapHomeCounterDetailContent], initialIndex: Int, dateText: String) {
        self.contents = contents
        self.dateText = dateText
        _selected = State(initialValue: min(max(initialIndex, 0), max(contents.count - 1, 0)))
    }

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            tabBar
            Divider().opacity(0.5)
            TabView(selection: $selected) {
                ForEach(Array(contents.enumerated()), id: \.offset) { index, content in
                    page(content).tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
        .background(Color.tpBackground)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("mapHomeCounterDetailSheet")
    }

    // MARK: 위쪽

    private var titleBar: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("카운터 상세")
                .font(.system(size: TaptionType.scaled(TaptionType.snapped(20)), weight: .bold, design: .rounded))
                .foregroundStyle(Color.tpInk)
            Spacer(minLength: 8)
            Text(dateText)
                .font(.system(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .semibold, design: .rounded))
                .foregroundStyle(Color.tpSecondary)
        }
        .padding(.horizontal, 20)
        .padding(.top, 26)
        .padding(.bottom, 12)
    }

    private var tabBar: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(contents.enumerated()), id: \.offset) { index, content in
                        tab(content, isSelected: index == selected)
                            .id(index)
                            .onTapGesture {
                                withAnimation(.snappy) { selected = index }
                            }
                            .accessibilityAddTraits(index == selected ? [.isButton, .isSelected] : .isButton)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
            }
            .onChange(of: selected) { _, index in
                withAnimation(.snappy) { proxy.scrollTo(index, anchor: .center) }
            }
            .onAppear { proxy.scrollTo(selected, anchor: .center) }
        }
    }

    private func tab(_ content: MapHomeCounterDetailContent, isSelected: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: content.systemImage)
                .font(.system(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .semibold))
            Text(content.title)
                .font(.system(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .bold, design: .rounded))
        }
        .foregroundStyle(isSelected ? Color.white : Color.tpInk)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background {
            Capsule().fill(isSelected ? Color.tpAccent : Color.tpSurface)
        }
        .overlay {
            Capsule().stroke(Color.tpLine.opacity(isSelected ? 0 : 0.7), lineWidth: 1)
        }
        .contentShape(Capsule())
    }

    // MARK: 아래쪽 상세

    private func page(_ content: MapHomeCounterDetailContent) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                hero(content)
                if !content.hourly.isEmpty { hourlyChart(content.hourly) }
                if let note = content.note {
                    Text(note)
                        .font(.system(size: TaptionType.scaled(TaptionType.snapped(14)), weight: .medium, design: .rounded))
                        .foregroundStyle(Color.tpSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .background(Color.tpSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                ForEach(content.sections) { section in
                    sectionCard(section)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 32)
        }
    }

    private func hero(_ content: MapHomeCounterDetailContent) -> some View {
        HStack(spacing: 14) {
            Image(systemName: content.systemImage)
                .font(.system(size: TaptionType.scaled(TaptionType.snapped(22)), weight: .semibold))
                .foregroundStyle(Color.tpAccent)
                .frame(width: 52, height: 52)
                .background(Color.tpAccent.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(content.title)
                    .font(.system(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.tpSecondary)
                Text(content.value)
                    .font(.system(size: TaptionType.scaled(TaptionType.snapped(32)), weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .foregroundStyle(Color.tpInk)
                if let caption = content.caption {
                    Text(caption)
                        .font(.system(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .medium, design: .rounded))
                        .foregroundStyle(Color.tpSecondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(Color.tpSurface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.tpLine.opacity(0.6), lineWidth: 1)
        }
    }

    /// 0시부터 24칸의 시간대별 막대. 가장 높은 시간대가 꽉 찬다.
    private func hourlyChart(_ values: [Double]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(value > 0 ? Color.tpAccent : Color.tpLine.opacity(0.5))
                        .frame(height: max(4, 72 * value))
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 72, alignment: .bottom)
            HStack {
                ForEach([0, 6, 12, 18, 24], id: \.self) { hour in
                    Text("\(hour)")
                        .font(.system(size: TaptionType.scaled(TaptionType.snapped(10)), weight: .medium, design: .rounded))
                        .foregroundStyle(Color.tpSecondary)
                    if hour != 24 { Spacer(minLength: 0) }
                }
            }
        }
        .padding(16)
        .background(Color.tpSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func sectionCard(_ section: MapHomeCounterDetailContent.Section) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(section.title)
                .font(.system(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .bold, design: .rounded))
                .foregroundStyle(Color.tpSecondary)
                .padding(.leading, 4)
            VStack(spacing: 0) {
                ForEach(Array(section.rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { Divider().padding(.leading, 16) }
                    rowView(row)
                }
            }
            .background(Color.tpSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private func rowView(_ row: MapHomeCounterDetailContent.Row) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title)
                        .font(.system(size: TaptionType.scaled(TaptionType.snapped(15)), weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.tpInk)
                    if let subtitle = row.subtitle {
                        Text(subtitle)
                            .font(.system(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .medium, design: .rounded))
                            .foregroundStyle(Color.tpSecondary)
                    }
                }
                Spacer(minLength: 8)
                if !row.value.isEmpty {
                    Text(row.value)
                        .font(.system(size: TaptionType.scaled(TaptionType.snapped(15)), weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Color.tpInk)
                }
            }
            if let share = row.share {
                shareBar(share)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func shareBar(_ share: Double) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.tpLine.opacity(0.45))
                Capsule()
                    .fill(Color.tpAccent)
                    .frame(width: max(4, proxy.size.width * min(max(share, 0), 1)))
            }
        }
        .frame(height: 5)
    }
}
