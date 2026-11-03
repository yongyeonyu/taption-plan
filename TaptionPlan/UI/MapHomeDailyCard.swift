import CoreMotion
import MapKit
import Photos
import SwiftUI
import UserNotifications

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
    /// 사용자가 골라 넣은 항목(최대 4개). 비어 있으면 통계 줄을 그리지 않는다.
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

/// 하루 카드 한 장의 값: 카드 그림 데이터와 항목 고르기 값(항목 id → 값).
struct MapHomeDailyCardContent {
    var data: MapHomeDailyCardData
    var values: [String: Double]

    /// 지도가 보고 있지 않은 날의 카드를 그날 기록으로 만든다. 확정한 날은 저장해 둔 값을 먼저 쓴다.
    @MainActor
    static func make(
        day: Date,
        snapshot: PlanDayDataSnapshot,
        sealedDays: [Date: TaptionSealedDay],
        placeKinds: [String: FrequentPlaceKind],
        hourlyRate: Double?,
        accessoryID: String?,
        memos: [ActionMemo],
        language: MapHomeLanguage,
        now: Date = .now,
        entries: ([String: TimeInterval]) -> [MapHomeDaySummaryEntry]
    ) -> MapHomeDailyCardContent {
        let calendar = Calendar.autoupdatingCurrent
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(24 * 60 * 60)
        let sealed = sealedDays[start]
        let seconds: [String: TimeInterval]
        if let sealed, !sealed.categorySeconds.isEmpty {
            seconds = sealed.categoryDurations
        } else {
            seconds = TaptionSealedDayBuilder.categoryDurations(
                actuals: snapshot.actuals, travel: snapshot.travel, stays: snapshot.places,
                placeKinds: placeKinds, day: TimeSpan(start: start, end: end), asOf: now
            )
        }
        let categories = entries(seconds)
        let total = categories.reduce(0) { $0 + $1.seconds }
        let distance = MapHomeDayTravelSummary.entries(from: snapshot.travel).reduce(0) { $0 + $1.meters }
        let work = categories.first { $0.id == MapHomeSalaryPolicy.workKey }?.seconds
        let steps = sealed.flatMap { $0.stepCount > 0 ? $0.stepCount : nil }
            ?? MapHomeCounterTimelinePolicy.stepCount(readings: snapshot.readings, cutoff: nil)
        let dayMemos = memos.filter { memo in
            let when = memo.isTimeless == true ? memo.createdAt : memo.occurredAt
            return when >= start && when < end
        }
        let mapMemoCount = dayMemos.filter { $0.mapPoint != nil }.count
        let routePoints: [GeoPoint]
        if let sealed, !sealed.polyline.isEmpty {
            routePoints = sealed.routePoints
        } else {
            routePoints = snapshot.readings.compactMap { reading in
                reading.point.map {
                    GeoPoint(latitude: $0.latitude, longitude: $0.longitude, altitude: 0, horizontalAccuracy: 0, verticalAccuracy: 0)
                }
            }
        }
        let isObservedToEnd = now >= end
        let data = MapHomeDailyCardData(
            dateText: start.formatted(Date.FormatStyle().month().day().locale(language.locale)),
            weekdayText: start.formatted(Date.FormatStyle().weekday(.wide).locale(language.locale)),
            earnedText: hourlyRate.map { rate in
                MapHomeSalaryPolicy.wonText(MapHomeSalaryPolicy.earnings(workSeconds: work ?? 0, hourlyRate: rate), language: language)
            },
            workText: work.map(MapHomeAlarmPolicy.hoursText),
            steps: steps,
            distanceText: distance > 0 ? MapHomeDayTravelSummary.distanceText(distance) : nil,
            categories: categories,
            totalText: language.text(
                "관측 \(MapHomeAlarmPolicy.hoursText(total))" + (isObservedToEnd ? "" : " · 나머지는 미확인"),
                "Observed \(MapHomeAlarmPolicy.hoursText(total))" + (isObservedToEnd ? "" : " · rest unconfirmed")
            ),
            accessoryID: accessoryID,
            memoText: dayMemos.isEmpty
                ? nil
                : language.text("메모 \(dayMemos.count)개 · 지도 \(mapMemoCount)개", "Memos \(dayMemos.count) · map \(mapMemoCount)"),
            routePoints: routePoints
        )
        var values = MapHomeCalendarTimeTotalsPolicy.totals(
            actuals: snapshot.actuals, travel: snapshot.travel, stays: snapshot.places,
            placeKinds: placeKinds, month: start, asOf: now, calendar: calendar, sealed: sealedDays
        )[start] ?? [:]
        if let steps { values[MapHomeCalendarTimeKind.steps.rawValue] = Double(steps) }
        return MapHomeDailyCardContent(data: data, values: values)
    }
}

/// 하루 카드에서 고를 수 있는 날짜. 오늘까지만 고른다.
enum MapHomeDailyCardDayPolicy {
    static func clamped(_ day: Date, now: Date, calendar: Calendar = .autoupdatingCurrent) -> Date {
        calendar.startOfDay(for: min(day, now))
    }

    static func canMoveForward(from day: Date, now: Date, calendar: Calendar = .autoupdatingCurrent) -> Bool {
        calendar.startOfDay(for: day) < calendar.startOfDay(for: now)
    }

    static func moved(_ day: Date, by days: Int, now: Date, calendar: Calendar = .autoupdatingCurrent) -> Date {
        let target = calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: day)) ?? day
        return clamped(target, now: now, calendar: calendar)
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

/// 카드 오른쪽 위 화랑이. 날짜로 장면을 뽑아 미리보기와 저장본이 같고, 날이 바뀌면 다른 장면이 나온다.
struct MapHomeDailyCardCat: View {
    let seedText: String
    let accessoryID: String?

    private var seed: Int {
        seedText.utf8.reduce(5381) { ($0 &* 33 &+ Int($1)) & 0xFFFF_FFFF }
    }

    var body: some View {
        let scenes = HwarangScene.allCases
        let scene = scenes[seed % scenes.count]
        HwarangSceneView(
            scene: scene,
            sec: Double(scene.totalDuration) * Double(seed % 97) / 97,
            width: 128,
            anchorHeight: 96,
            hatAssetName: MapHomeGrowthAccessoryCatalog.hatAssetName(for: accessoryID),
            scarf: MapHomeGrowthAccessoryCatalog.scarfStyle(for: accessoryID),
            ribbon: MapHomeGrowthAccessoryCatalog.ribbonStyle(for: accessoryID),
            showsBackdrop: false
        )
        .frame(width: 96, height: 96)
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
                        Text(data.dateText).font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(34)), weight: .bold))
                        Text(data.weekdayText).font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(18)), weight: .semibold)).foregroundStyle(Color.tpSecondary)
                    }
                    Spacer()
                    MapHomeDailyCardCat(seedText: data.dateText, accessoryID: data.accessoryID)
                }
                if !data.metrics.isEmpty {
                    // 사용자가 고른 항목(최대 4개)을 카드 윗부분에 그대로 보여 준다.
                    HStack(spacing: 10) {
                        ForEach(data.metrics) { metric in
                            stat(metric.title, metric.value, metric.systemImage)
                        }
                    }
                }
                // 고른 항목이 없으면 통계 줄을 아예 그리지 않는다. 예전에는 비어 있으면 기본 항목이 채워졌다(대표 지시, ARC1030A11).
                VStack(alignment: .leading, spacing: 10) {
                    Text(data.totalText).font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(14)), weight: .semibold)).foregroundStyle(Color.tpSecondary)
                    ForEach(data.categories.prefix(5)) { entry in
                        HStack(spacing: 10) {
                            TaptionCuteIcon(entry.systemImage).foregroundStyle(entry.tint).frame(width: 22)
                            Text(entry.title).font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(16)), weight: .semibold)).frame(width: 90, alignment: .leading)
                            GeometryReader { proxy in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color.tpLine.opacity(0.5))
                                    Capsule().fill(entry.tint).frame(width: max(6, proxy.size.width * entry.ratio))
                                }
                            }
                            .frame(height: 12)
                            Text(MapHomeAlarmPolicy.hoursText(entry.seconds))
                                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(14)), weight: .semibold)).monospacedDigit()
                                .frame(width: 96, alignment: .trailing)
                            Text("\(Int((entry.ratio * 100).rounded()))%").font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(15)), weight: .bold)).monospacedDigit().frame(width: 46, alignment: .trailing)
                        }
                    }
                }
                Spacer(minLength: 0)
                HStack {
                    Text("BOKKI Plan").font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(14)), weight: .bold)).foregroundStyle(Color.tpAccent)
                    Spacer()
                    Text(language.text("자동 기록으로 만든 하루", "A day from automatic records"))
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .medium)).foregroundStyle(Color.tpSecondary)
                }
            }
            .padding(36)
            .foregroundStyle(Color.tpInk)
        }
        .frame(width: Self.side, height: Self.side)
    }

    private func stat(_ title: String, _ value: String, _ symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                TaptionCuteIcon(symbol, size: 16)
                Text(title)
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .foregroundStyle(Color.tpSecondary)
            Text(value).font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(20)), weight: .bold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.tpCard.opacity(0.55), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// 카드 미리보기와 저장·공유.
struct MapHomeDailyCardSheet: View {
    let language: MapHomeLanguage
    /// 화면이 바뀔 때마다 다시 만들지 않도록, 시트가 열릴 때와 날짜를 바꿀 때만 부른다.
    let makeContent: @MainActor (Date) async -> MapHomeDailyCardContent
    /// 카드 안에서 고른 날짜. 지도 날짜와 별개다.
    @State private var selectedDay: Date
    @State private var loadedDay: Date?
    /// 날짜를 하나 읽을 때마다 오른다. 경로 지도를 그날 것으로 다시 그리는 신호다.
    @State private var loadGeneration = 0
    /// 카드 그림이 고른 날짜로 다 그려졌는지. 그 전에는 저장·공유를 막는다.
    @State private var isDayReady = false
    @State private var baseData: MapHomeDailyCardData?
    /// 하루 달력 값(항목 id → 값). 고르기 목록과 카드에 쓴다.
    @State private var dayValues: [String: Double] = [:]
    @State private var image: UIImage?
    @State private var mapImage: UIImage?
    @State private var shareURL: URL?
    @State private var message: String?
    @State private var selectedIDs: [String] = MapHomeCardMetricSelection.load()
    @State private var isPickerPresented = false

    init(
        initialDay: Date,
        language: MapHomeLanguage,
        makeContent: @escaping @MainActor (Date) async -> MapHomeDailyCardContent
    ) {
        self.language = language
        self.makeContent = makeContent
        _selectedDay = State(initialValue: MapHomeDailyCardDayPolicy.clamped(initialDay, now: .now))
    }

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

    /// 제목 오른쪽의 날짜 고르기와 전날·다음날 이동.
    private var header: some View {
        HStack(spacing: 4) {
            Text(language.text("하루 카드", "Day card"))
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(22)), weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 4)
            dayStepButton("chevron.left", label: language.text("전날", "Previous day"), by: -1, isEnabled: true)
            DatePicker(
                language.text("날짜", "Date"),
                selection: Binding(
                    get: { selectedDay },
                    set: { selectedDay = MapHomeDailyCardDayPolicy.clamped($0, now: .now) }
                ),
                in: ...Date.now,
                displayedComponents: .date
            )
            .labelsHidden()
            .datePickerStyle(.compact)
            .tint(Color.tpAccent)
            .environment(\.locale, language.locale)
            dayStepButton(
                "chevron.right",
                label: language.text("다음날", "Next day"),
                by: 1,
                isEnabled: MapHomeDailyCardDayPolicy.canMoveForward(from: selectedDay, now: .now)
            )
        }
    }

    private func dayStepButton(_ symbol: String, label: String, by days: Int, isEnabled: Bool) -> some View {
        Button {
            selectedDay = MapHomeDailyCardDayPolicy.moved(selectedDay, by: days, now: .now)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: TaptionType.scaled(TaptionType.snapped(15)), weight: .bold))
                .foregroundStyle(isEnabled ? Color.tpInk : Color.tpLine)
                .frame(width: 32, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(label)
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
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(14)), weight: .semibold))
            HStack(spacing: 8) {
                ForEach(0..<MapHomeCardMetricSelection.maximum, id: \.self) { index in
                    slot(index)
                }
            }
            Button {
                isPickerPresented = true
            } label: {
                Label(language.text("항목 추가", "Add item"), systemImage: "plus.circle.fill")
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(14)), weight: .bold))
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
                    TaptionCuteIcon(filled.systemImage).foregroundStyle(Color.tpAccent)
                    Text(filled.title(language)).font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(10)), weight: .semibold)).lineLimit(1).minimumScaleFactor(0.6)
                    Text(MapHomeCardMetricSelection.value(for: filled, number: dayValues[filled.rawValue] ?? 0))
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .bold)).lineLimit(1).minimumScaleFactor(0.6)
                } else {
                    Image(systemName: "plus").font(.system(size: TaptionType.scaled(TaptionType.snapped(16)), weight: .bold)).foregroundStyle(Color.tpSecondary)
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
                            TaptionCuteIcon(kind.systemImage).foregroundStyle(Color.tpAccent).frame(width: 24)
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
                header
                metricPanel
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
                        .opacity(isDayReady ? 1 : 0.45)
                        .overlay { if !isDayReady { ProgressView() } }
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
                .disabled(image == nil || !isDayReady)
                if let message {
                    Text(message).font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .medium)).foregroundStyle(Color.tpAccent)
                }
                Text(language.text("1080×1080 · 인스타그램 피드 크기", "1080×1080 · Instagram feed size"))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(12)))).foregroundStyle(Color.tpSecondary)
            }
            .padding(22)
        }
        .background(Color.tpBackground)
        // 열릴 때와 날짜를 바꿀 때 그날 값을 읽는다. 이후에는 항목을 고를 때만 카드가 다시 그려진다.
        .task(id: selectedDay) {
            isDayReady = false
            message = nil
            let content = await makeContent(selectedDay)
            guard !Task.isCancelled else { return }
            mapImage = nil
            baseData = content.data
            dayValues = content.values
            loadedDay = selectedDay
            loadGeneration += 1
        }
        // 지도는 날짜를 읽었을 때만 다시 그리고, 다 그린 뒤에야 저장·공유를 연다(앞 날짜의 경로가 섞이지 않게).
        .task(id: loadGeneration) {
            guard loadGeneration > 0 else { return }
            let map = await Self.routeMap(points: baseData?.routePoints ?? [])
            guard !Task.isCancelled else { return }
            mapImage = map
            image = Self.render(data: data, language: language, mapImage: map)
            if loadedDay == selectedDay { isDayReady = true }
        }
        .task(id: data) {
            guard isDayReady else { return }
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
