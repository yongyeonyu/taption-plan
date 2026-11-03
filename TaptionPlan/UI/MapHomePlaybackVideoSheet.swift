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
    @State private var customStart = Calendar.autoupdatingCurrent.date(byAdding: .day, value: -3, to: .now) ?? .now
    @State private var customEnd = Date.now
    @State private var rangePlan: MapHomeRangeTripPlan?
    @State private var isLoadingRange = false

    /// 0은 기간에 따라 자동.
    private static let lengthChoices = [0, 30, 60, 90, 180]

    private var preset: MapHomeRangePreset { MapHomeRangePreset(rawValue: presetRaw) ?? .day }

    private var rangeSpan: TimeSpan {
        preset.span(selectedDate: selectedDate, customStart: customStart, customEnd: customEnd, now: .now)
    }

    private var rangeKey: String {
        "\(presetRaw)|\(targetSeconds)|\(hidesPrivatePlaces)|\(Int(customStart.timeIntervalSinceReferenceDate / 86_400))|\(Int(customEnd.timeIntervalSinceReferenceDate / 86_400))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(language.text("재생 영상 만들기", "Make playback video"))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(20)), weight: .bold))
                    .foregroundStyle(Color.tpInk)
                Spacer(minLength: 8)
                Button(phase == .rendering ? language.text("취소", "Cancel") : language.text("닫기", "Close")) {
                    task?.cancel()
                    dismiss()
                }
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(15)), weight: .semibold))
                .foregroundStyle(Color.tpAccent)
            }
            if phase == .idle || isFailed {
                rangeControls
            }
            VStack(alignment: .leading, spacing: 10) {
                Text(message)
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .medium))
                    .foregroundStyle(Color.tpSecondary)
                if phase == .rendering || phase == .saving {
                    ProgressView(value: progress)
                        .tint(Color.tpAccent)
                    Text("\(Int((progress * 100).rounded(.down)))%")
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .semibold).monospacedDigit())
                        .foregroundStyle(Color.tpSecondary)
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.tpBackground)
        .presentationBackground(Color.tpBackground)
        // 닫기·아래로 쓸기 모두 여기로 온다. 만드는 중이면 렌더링을 멈춘다.
        .onDisappear { task?.cancel() }
        .task(id: rangeKey) { await loadRange() }
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    private var rangeControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            choiceRow(MapHomeRangePreset.allCases.map { ($0.rawValue, title(for: $0)) }, selected: presetRaw) { presetRaw = $0 }
            if preset == .custom {
                DatePicker(language.text("시작", "From"), selection: $customStart, in: ...Date.now, displayedComponents: .date)
                DatePicker(language.text("끝", "To"), selection: $customEnd, in: ...Date.now, displayedComponents: .date)
            }
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

    private func title(for preset: MapHomeRangePreset) -> String {
        switch preset {
        case .day: language.text("이 날", "This day")
        case .recentSevenDays: language.text("최근 7일", "7 days")
        case .lastMonth: language.text("지난달", "Last month")
        case .custom: language.text("직접 지정", "Custom")
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
        guard let style = model.settings.mapDisplayStyle.runtimeStyle.mapHomeVectorStyle else { return nil }
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

    /// 하루씩 읽어 위치 표본만 남긴다. 여러 날의 `SensorReading`을 한꺼번에 메모리에 두지 않는다.
    private func loadRange() async {
        rangePlan = nil
        guard preset != .day else { return }
        isLoadingRange = true
        defer { isLoadingRange = false }
        let span = rangeSpan
        let days = max(1, Int((span.duration / 86_400).rounded(.up)))
        let seconds = Double(targetSeconds == 0 ? MapHomeRangePreset.automaticSeconds(forDays: days) : targetSeconds)
        let hiddenPlaces = hiddenPlaces
        let calendar = Calendar.autoupdatingCurrent
        var samples: [MapHomeRangeTripPlan.Sample] = []
        var dayStart = span.start
        while dayStart < span.end {
            let next = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: dayStart)) ?? span.end
            let readings = await model.sensorReadingsLoadResult(in: TimeSpan(start: dayStart, end: min(next, span.end))).readings
            samples += MapHomeRangeTripPlan.samples(from: readings)
            if Task.isCancelled { return }
            dayStart = next
        }
        let plan = await Self.makePlan(samples: samples, span: span, seconds: seconds, hiddenPlaces: hiddenPlaces)
        guard !Task.isCancelled else { return }
        rangePlan = plan
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
        if isLoadingRange { return language.text("기록을 읽는 중입니다.", "Reading your records.") }
        guard let rangePlan else {
            return language.text("이 기간에는 보여 줄 위치 기록이 없습니다.", "No location records to show in this period.")
        }
        let kilometers = Int(rangePlan.totalMeters / 1_000).formatted()
        return language.text(
            "\(rangePlan.dayCount)일, 이동 \(kilometers)km를 \(lengthTitle(Int(rangePlan.durationSeconds))) 영상으로 그립니다.",
            "\(rangePlan.dayCount) days, \(kilometers) km in a \(lengthTitle(Int(rangePlan.durationSeconds))) video."
        )
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
            phase = .idle
        } catch MapHomePlaybackVideoError.empty {
            phase = .failed(language.text("보여 줄 위치 기록이 없습니다.", "No location records to show."))
        } catch {
            phase = .failed(language.text("영상을 만들지 못했습니다.", "Could not make the video."))
        }
        task = nil
    }
}
