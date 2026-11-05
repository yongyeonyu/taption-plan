import SwiftUI

/// 하루 재생을 영상으로 만들어 사진 앱에 저장하는 시트(VID1029A01).
/// 입력은 부모가 `makeRenderer`로 넘긴다. 시트는 진행·취소·결과만 맡는다.
struct MapHomePlaybackVideoSheet: View {
    let model: AppModel
    let language: MapHomeLanguage
    let selectedDate: Date
    let accessoryID: String?
    let makeRenderer: @MainActor ([MapHomeRangeTripPlan.Point]) -> MapHomePlaybackVideoRenderer?

    private enum Phase: Equatable {
        case idle
        case rendering
        case saving
        case saved
        case failed(String)
    }

    @Environment(\.dismiss) private var dismiss
    @State private var phase = Phase.idle
    @State private var progress = 0.0
    @State private var task: Task<Void, Never>?
    @AppStorage("playbackVideoRangePreset") private var presetRaw = MapHomeRangePreset.day.rawValue
    @AppStorage("playbackVideoRangeSeconds") private var targetSeconds = 0
    @AppStorage("playbackVideoHidesPrivatePlaces") private var hidesPrivatePlaces = true
    @State private var isClosing = false
    @AppStorage("playbackVideoMusic") private var musicRaw = MapHomePlaybackMusicTrack.defaultID
    @AppStorage(MapHomePlaybackRangePicker.customStartKey) private var customStartRaw = 0.0
    @AppStorage(MapHomePlaybackRangePicker.customEndKey) private var customEndRaw = 0.0
    @State private var rangePlan: MapHomeRangeTripPlan?
    @State private var isLoadingRange = false
    @State private var rangeLoadPercent = 0
    /// 구간 안에서 위치 기록을 읽지 못한 날 수. 없는 경로를 지어내지 않고 알려 준다.
    @State private var missingRangeDays = 0
    /// 영상 길이·가리기만 바꿀 때 1년치를 다시 읽지 않도록 줄인 표본을 시트가 열린 동안 둔다.
    @State private var loadedRange: (span: TimeSpan, samples: [MapHomeRangeTripPlan.Sample], missing: Int)?

    /// 0은 기간에 따라 자동.
    private static let lengthChoices = [0, 30, 60, 90, 180]

    private var preset: MapHomeRangePreset { MapHomeRangePreset.stored(presetRaw) }

    private var musicTrack: MapHomePlaybackMusicTrack? { MapHomePlaybackMusicTrack.stored(musicRaw) }

    private var customStart: Date { MapHomePlaybackRangePicker.customStart(customStartRaw) }
    private var customEnd: Date { MapHomePlaybackRangePicker.customEnd(customEndRaw) }

    private var rangeSpan: TimeSpan {
        preset.span(selectedDate: selectedDate, customStart: customStart, customEnd: customEnd, now: .now)
    }

    private var rangeKey: String {
        "\(presetRaw)|\(targetSeconds)|\(hidesPrivatePlaces)|\(Int(customStart.timeIntervalSinceReferenceDate / 86_400))|\(Int(customEnd.timeIntervalSinceReferenceDate / 86_400))"
    }

    var body: some View {
        ScrollView {
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.tpBackground)
        .presentationBackground(Color.tpBackground)
        // 만드는 중에는 쓸어 내리지 않는다. 캡처가 화면 갱신을 강제해 시트가 떨린다. 취소 단추로 닫는다.
        .interactiveDismissDisabled(phase == .rendering)
        // 닫기·아래로 쓸기 모두 여기로 온다. 만드는 중이면 렌더링을 멈춘다.
        .onDisappear {
            task?.cancel()
        }
        .task(id: rangeKey) { await loadRange() }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(language.text("재생 영상 만들기", "Make playback video"))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(20)), weight: .bold))
                    .foregroundStyle(Color.tpInk)
                Spacer(minLength: 8)
                Button(phase == .rendering ? language.text("취소", "Cancel") : language.text("닫기", "Close")) {
                    isClosing = true
                    task?.cancel()
                    dismiss()
                }
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(15)), weight: .semibold))
                .foregroundStyle(Color.tpAccent)
            }
            if phase == .idle || isFailed {
                rangeControls
                MapHomePlaybackMusicPicker(language: language, canUseAudio: !model.isRecordingVoiceMemo)
            }
            VStack(alignment: .leading, spacing: 10) {
                Text(periodText)
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(14)), weight: .bold))
                    .foregroundStyle(Color.tpInk)
                Text(message)
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .medium))
                    .foregroundStyle(Color.tpSecondary)
                if phase == .rendering || phase == .saving {
                    progressRow(progress)
                } else if isLoadingRange {
                    progressRow(Double(rangeLoadPercent) / 100)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.tpSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.tpLine, lineWidth: 1)
            }
            actionButton
        }
        .padding(22)
    }

    @ViewBuilder
    private func progressRow(_ value: Double) -> some View {
        ProgressView(value: value)
            .tint(Color.tpAccent)
        Text("\(Int((value * 100).rounded(.down)))%")
            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .semibold).monospacedDigit())
            .foregroundStyle(Color.tpSecondary)
    }

    /// 영상에 담기는 기간. 끝은 다음 날 0시일 수 있어 1초 빼서 보여 준다.
    private var periodText: String {
        let format = Date.FormatStyle().year().month().day()
        let span = rangeSpan
        let lastMoment = max(span.start, span.end.addingTimeInterval(-1))
        guard !Calendar.autoupdatingCurrent.isDate(span.start, inSameDayAs: lastMoment) else {
            return span.start.formatted(format)
        }
        return "\(span.start.formatted(format)) – \(lastMoment.formatted(format))"
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    private var rangeControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            MapHomePlaybackRangePicker(language: language)
            if preset != .day {
                choiceRow(Self.lengthChoices.map { (String($0), lengthTitle($0)) }, selected: String(targetSeconds)) {
                    targetSeconds = Int($0) ?? 0
                }
            }
            Toggle(language.text("집·직장 주변 가리기", "Hide home and work areas"), isOn: $hidesPrivatePlaces)
        }
        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(14)), weight: .medium))
    }

    private func choiceRow(_ choices: [(String, String)], selected: String, select: @escaping (String) -> Void) -> some View {
        HStack(spacing: 6) {
            ForEach(choices, id: \.0) { id, label in
                Button { select(id) } label: {
                    Text(label)
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .foregroundStyle(id == selected ? Color.white : Color.tpInk)
                        .background(id == selected ? Color.tpPrimaryFill : Color.tpSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func lengthTitle(_ seconds: Int) -> String {
        if seconds == 0 { return language.text("자동", "Auto") }
        return seconds < 60
            ? language.text("\(seconds)초", "\(seconds)s")
            : language.text(seconds % 60 == 0 ? "\(seconds / 60)분" : "\(seconds / 60)분 \(seconds % 60)초", seconds % 60 == 0 ? "\(seconds / 60)m" : "\(seconds / 60)m \(seconds % 60)s")
    }

    private var hiddenPlaces: [MapHomeRangeTripPlan.Point] {
        hidesPrivatePlaces ? MapHomeRangeTripPlan.hiddenPlaces(from: model.settings.frequentPlaces) : []
    }

    /// 여러 날 구간을 영상으로 그린다.
    private func makeRangeRenderer(_ plan: MapHomeRangeTripPlan) -> MapHomePlaybackVideoRenderer? {
        // Apple 지도는 영상으로 그릴 수 없어 하루 영상과 같은 기본 벡터 스타일을 쓴다.
        guard let style = model.settings.mapDisplayStyle.runtimeStyle.mapHomeVectorStyle
            ?? MapDisplayStyle.mapLibreRPG.runtimeStyle.mapHomeVectorStyle else { return nil }
        return MapHomePlaybackVideoRenderer(
            style: style,
            frames: { plan.frames(fps: $0) },
            overlay: MapHomeRangeVideoOverlay(plan: plan, language: language, accessoryID: accessoryID)
        )
    }

    /// 주 스레드 밖에서 계획을 만든다.
    private nonisolated static func makePlan(
        samples: [MapHomeRangeTripPlan.Sample],
        span: TimeSpan,
        seconds: Double,
        hiddenPlaces: [MapHomeRangeTripPlan.Point]
    ) async -> MapHomeRangeTripPlan? {
        MapHomeRangeTripPlan.make(samples: samples, span: span, durationSeconds: seconds, hiddenPlaces: hiddenPlaces)
    }

    /// 주 스레드 밖에서 하루치를 표본으로 줄인다.
    private nonisolated static func daySamples(from readings: [SensorReading]) async -> [MapHomeRangeTripPlan.Sample] {
        MapHomeRangeTripPlan.thinned(
            MapHomeRangeTripPlan.samples(from: readings).sorted { $0.time < $1.time }
        )
    }

    private nonisolated static func cachedSamples(dayStart: Date, calendar: Calendar) async -> [MapHomeRangeTripPlan.Sample]? {
        MapHomeRangeSampleCache.read(dayStart: dayStart, calendar: calendar)
    }

    private nonisolated static func storeSamples(
        _ samples: [MapHomeRangeTripPlan.Sample], dayStart: Date, calendar: Calendar
    ) async {
        guard MapHomeRangeSampleCache.isCacheable(dayStart: dayStart, now: .now, calendar: calendar) else { return }
        MapHomeRangeSampleCache.write(samples, dayStart: dayStart, calendar: calendar)
    }

    /// 하루씩 읽어 줄인 표본만 남긴다. 여러 날의 `SensorReading`을 한꺼번에 메모리에 두지 않는다.
    /// 판독이 없는 날은 저장된 이동·장소로 경로를 지어내지 않고 날 수만 센다.
    private func loadRange() async {
        rangePlan = nil
        missingRangeDays = 0
        if isFailed { phase = .idle }
        guard preset != .day else { return }
        isLoadingRange = true
        rangeLoadPercent = 0
        defer { isLoadingRange = false }
        let span = rangeSpan
        let days = max(1, Int((span.duration / 86_400).rounded(.up)))
        let seconds = Double(targetSeconds == 0 ? MapHomeRangePreset.automaticSeconds(forDays: days) : targetSeconds)
        let hiddenPlaces = hiddenPlaces
        let calendar = Calendar.autoupdatingCurrent
        let loaded: (span: TimeSpan, samples: [MapHomeRangeTripPlan.Sample], missing: Int)
        if let cached = loadedRange, calendar.isDate(cached.span.start, inSameDayAs: span.start),
           calendar.isDate(cached.span.end, inSameDayAs: span.end) {
            loaded = cached
        } else {
            guard let read = await readRange(span, days: days, calendar: calendar) else { return }
            loaded = read
            loadedRange = read
        }
        let plan = await Self.makePlan(samples: loaded.samples, span: span, seconds: seconds, hiddenPlaces: hiddenPlaces)
        guard !Task.isCancelled else { return }
        rangePlan = plan
        missingRangeDays = loaded.missing
    }

    /// 취소되면 nil.
    private func readRange(
        _ span: TimeSpan, days: Int, calendar: Calendar
    ) async -> (span: TimeSpan, samples: [MapHomeRangeTripPlan.Sample], missing: Int)? {
        var samples: [MapHomeRangeTripPlan.Sample] = []
        var missing = 0
        var dayIndex = 0
        var dayStart = span.start
        while dayStart < span.end {
            let next = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: dayStart)) ?? span.end
            let daySamples: [MapHomeRangeTripPlan.Sample]
            if let cached = await Self.cachedSamples(dayStart: dayStart, calendar: calendar) {
                daySamples = cached
            } else {
                let loaded = await model.routeReadingsForRange(in: TimeSpan(start: dayStart, end: min(next, span.end)))
                daySamples = await Self.daySamples(from: loaded.readings)
                if Task.isCancelled { return nil }
                await Self.storeSamples(daySamples, dayStart: dayStart, calendar: calendar)
            }
            if Task.isCancelled { return nil }
            samples += daySamples
            if daySamples.isEmpty { missing += 1 }
            dayIndex += 1
            let percent = min(100, dayIndex * 100 / days)
            if percent != rangeLoadPercent { rangeLoadPercent = percent }
            dayStart = next
        }
        return (span, samples, missing)
    }

    private var message: String {
        switch phase {
        case .idle:
            idleMessage
        case .rendering:
            language.text("영상을 그리는 중입니다. 앱을 켜 둔 채 기다려 주세요.", "Rendering. Keep the app open.")
        case .saving:
            language.text("사진 앱에 저장하는 중입니다.", "Saving to Photos.")
        case .saved:
            language.text("사진에 저장됨", "Saved to Photos")
        case .failed(let reason):
            reason
        }
    }

    private var idleMessage: String {
        guard preset != .day else {
            return language.text("하루 재생을 60fps 영상으로 그립니다. 끊김 없이 저장됩니다.", "Renders the day at 60 fps with no dropped frames.")
        }
        if isLoadingRange {
            return language.text(
                "기록을 읽는 중입니다. 처음에는 기간이 길수록 오래 걸리고, 한 번 읽은 날은 다음부터 바로 열립니다.",
                "Reading your records. The first read takes longer for long periods; days already read open instantly next time."
            )
        }
        guard let rangePlan else {
            return language.text("이 기간에는 보여 줄 위치 기록이 없습니다.", "No location records to show in this period.")
        }
        let distance = AppRegion.current.longDistanceText(meters: rangePlan.totalMeters)
        let summary = language.text(
            "\(rangePlan.dayCount)일, 이동 \(distance)를 \(lengthTitle(Int(rangePlan.durationSeconds))) 영상으로 그립니다.",
            "\(rangePlan.dayCount) days, \(distance) in a \(lengthTitle(Int(rangePlan.durationSeconds))) video."
        )
        guard missingRangeDays > 0 else { return summary }
        let missing = language.text(
            "위치 기록이 없는 \(missingRangeDays)일은 경로가 없어 앞뒤 지점을 바로 잇습니다.",
            "\(missingRangeDays) days have no location records; the points around them are joined directly."
        )
        return summary + "\n" + missing
    }

    private var canStart: Bool { preset == .day || rangePlan != nil }

    @ViewBuilder
    private var actionButton: some View {
        switch phase {
        case .rendering, .saving:
            EmptyView()
        case .saved:
            Label(language.text("사진에 저장됨", "Saved to Photos"), systemImage: "checkmark.circle.fill")
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(15)), weight: .bold))
                .foregroundStyle(Color.tpAccent)
        case .idle, .failed:
            Button(action: start) {
                Label(language.text("영상 만들기", "Make video"), systemImage: "film")
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(16)), weight: .bold))
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .foregroundStyle(.white)
                    .background(Color.tpPrimaryFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!canStart)
            .opacity(canStart ? 1 : 0.5)
        }
    }

    private func start() {
        let made = preset == .day ? makeRenderer(hiddenPlaces) : rangePlan.flatMap(makeRangeRenderer)
        guard let renderer = made else {
            phase = .failed(language.text("재생할 기록이 없습니다.", "Nothing to play back."))
            return
        }
        renderer.music = musicTrack?.url
        renderer.fps = preset == .day ? MapHomePlaybackVideoRenderer.dayFPS : MapHomePlaybackVideoRenderer.rangeFPS
        progress = 0
        phase = .rendering
        task = Task { await run(renderer) }
    }

    private func run(_ renderer: MapHomePlaybackVideoRenderer) async {
        do {
            let url = try await renderer.render { value in
                if value != progress { progress = value }
            }
            defer { try? FileManager.default.removeItem(at: url) }
            // 다 그린 직후에 닫았으면 사진에 넣지 않는다.
            try Task.checkCancellation()
            phase = .saving
            let saved = await MapHomePlaybackVideoRenderer.saveToPhotos(url)
            phase = saved
                ? .saved
                : .failed(language.text("사진 저장 권한이 필요합니다.", "Photo saving permission is needed."))
        } catch is CancellationError {
            // 닫히는 중에 화면을 되돌리면 시트 안 내용이 튄다.
            if !isClosing { phase = .idle }
        } catch MapHomePlaybackVideoError.empty {
            phase = .failed(language.text("보여 줄 위치 기록이 없습니다.", "No location records to show."))
        } catch {
            phase = .failed(language.text("영상을 만들지 못했습니다.", "Could not make the video."))
        }
        task = nil
    }
}

/// 영상 기간 드롭다운과 특정 날짜. 영상 화면과 녹화 화면이 같은 값을 쓴다(REC1105A01).
struct MapHomePlaybackRangePicker: View {
    static let presetKey = "playbackVideoRangePreset"
    static let customStartKey = "playbackVideoCustomStart"
    static let customEndKey = "playbackVideoCustomEnd"

    let language: MapHomeLanguage

    @AppStorage(presetKey) private var presetRaw = MapHomeRangePreset.day.rawValue
    @AppStorage(customStartKey) private var customStartRaw = 0.0
    @AppStorage(customEndKey) private var customEndRaw = 0.0

    static func customStart(_ raw: Double) -> Date {
        raw > 0
            ? Date(timeIntervalSinceReferenceDate: raw)
            : Calendar.autoupdatingCurrent.date(byAdding: .day, value: -3, to: .now) ?? .now
    }

    static func customEnd(_ raw: Double) -> Date {
        raw > 0 ? Date(timeIntervalSinceReferenceDate: raw) : .now
    }

    private var preset: MapHomeRangePreset { MapHomeRangePreset.stored(presetRaw) }

    private func title(_ preset: MapHomeRangePreset) -> String {
        switch preset {
        case .day: language.text("1일", "1 day")
        case .week: language.text("1주일", "1 week")
        case .month: language.text("1달", "1 month")
        case .year: language.text("1년", "1 year")
        case .custom: language.text("특정 날짜", "Custom")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Menu {
                Picker(language.text("기간", "Period"), selection: $presetRaw) {
                    ForEach(MapHomeRangePreset.allCases, id: \.rawValue) { preset in
                        Text(title(preset)).tag(preset.rawValue)
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "calendar")
                    Text(language.text("기간", "Period"))
                    Spacer(minLength: 4)
                    Text(title(preset))
                        .foregroundStyle(Color.tpSecondary)
                    Image(systemName: "chevron.up.chevron.down")
                }
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: 40)
                .foregroundStyle(Color.tpInk)
                .background(Color.tpSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .accessibilityIdentifier("playbackRangeMenu")
            if preset == .custom {
                DatePicker(
                    language.text("시작", "From"),
                    selection: Binding(
                        get: { Self.customStart(customStartRaw) },
                        set: { customStartRaw = $0.timeIntervalSinceReferenceDate }
                    ),
                    in: ...Date.now,
                    displayedComponents: .date
                )
                DatePicker(
                    language.text("끝", "To"),
                    selection: Binding(
                        get: { Self.customEnd(customEndRaw) },
                        set: { customEndRaw = $0.timeIntervalSinceReferenceDate }
                    ),
                    in: ...Date.now,
                    displayedComponents: .date
                )
            }
        }
        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(14)), weight: .semibold))
    }
}
