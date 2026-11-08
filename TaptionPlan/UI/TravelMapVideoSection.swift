import SwiftUI

/// 재생 영상 시트의 「도시 여행 지도」 칸(TRV1108A01). 기록에서 들른 도시를 뽑거나 직접 넣은 여행으로
/// 세로 MP4를 만들어 사진 앱에 저장한다. 진행·취소·결과는 이 칸이 맡고, 시트에는 바쁜지만 알린다.
struct TravelMapVideoSection: View {
    let model: AppModel
    let language: MapHomeLanguage
    let span: TimeSpan
    @Binding var isBusy: Bool

    private enum Phase: Equatable {
        case idle, rendering, saving, saved
        case failed(String)
    }

    @AppStorage("travelMapVideoSource") private var sourceRaw = "records"
    @AppStorage("playbackVideoMusic") private var musicRaw = MapHomePlaybackMusicTrack.defaultID
    @State private var recordTrip: TravelMapTrip?
    @State private var isLoading = false
    @State private var loadPercent = 0
    @State private var manualTrip = TravelMapTripDraftStore.load()
    @State private var isEditing = false
    @State private var phase = Phase.idle
    @State private var progress = 0.0
    @State private var task: Task<Void, Never>?

    private var isManual: Bool { sourceRaw == "manual" }
    private var trip: TravelMapTrip? { isManual ? manualTrip : recordTrip }
    private var loadKey: String {
        "\(sourceRaw)|\(Int(span.start.timeIntervalSinceReferenceDate))|\(Int(span.end.timeIntervalSinceReferenceDate))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !isBusy {
                Picker(language.text("자료", "Source"), selection: $sourceRaw) {
                    Text(language.text("내 기록", "My records")).tag("records")
                    Text(language.text("직접 입력", "Enter manually")).tag("manual")
                }
                .pickerStyle(.segmented)
            }
            statusCard
            buttons
        }
        .task(id: loadKey) { await loadRecords() }
        .onChange(of: manualTrip) { _, value in TravelMapTripDraftStore.save(value) }
        .onChange(of: phase) { _, value in
            let busy = value == .rendering || value == .saving
            if busy != isBusy { isBusy = busy }
        }
        .onDisappear {
            task?.cancel()
            isBusy = false
        }
        .sheet(isPresented: $isEditing) {
            TravelMapTripEditorSheet(language: language, trip: $manualTrip)
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let trip, trip.isRenderable {
                routeText(trip)
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(14)), weight: .bold))
                    .foregroundStyle(Color.tpInk)
                Text(summary(trip))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .semibold).monospacedDigit())
                    .foregroundStyle(Color.tpSecondary)
            }
            Text(message)
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .medium))
                .foregroundStyle(Color.tpSecondary)
            if phase == .rendering || phase == .saving {
                progressRow(progress)
            } else if isLoading && !isManual {
                progressRow(Double(loadPercent) / 100)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.tpSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.tpLine, lineWidth: 1)
        }
    }

    /// 「서울 🚄 부산 ✈︎ 제주」처럼 도시 사이에 수단 아이콘을 끼운다. 길면 옆으로 민다.
    private func routeText(_ trip: TravelMapTrip) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(trip.stops.enumerated()), id: \.element.id) { index, stop in
                    if index > 0 {
                        Image(systemName: stop.arrivalMode.symbolName)
                            .foregroundStyle(Color.tpAccent)
                            .accessibilityLabel(stop.arrivalMode.title(language))
                    }
                    Text(stop.name)
                }
            }
        }
    }

    private func summary(_ trip: TravelMapTrip) -> String {
        let cities = Set(trip.stops.map(\.name)).count
        return language.text("도시 \(cities)곳", "\(cities) cities") + " · " + AppRegion.current.longDistanceText(meters: trip.totalMeters)
    }

    @ViewBuilder
    private func progressRow(_ value: Double) -> some View {
        ProgressView(value: value)
            .tint(Color.tpAccent)
        Text("\(Int((value * 100).rounded(.down)))%")
            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .semibold).monospacedDigit())
            .foregroundStyle(Color.tpSecondary)
    }

    private var message: String {
        switch phase {
        case .rendering:
            return language.text("영상을 그리는 중입니다. 앱을 켜 둔 채 기다려 주세요.", "Rendering. Keep the app open.")
        case .saving:
            return language.text("사진 앱에 저장하는 중입니다.", "Saving to Photos.")
        case .saved:
            return language.text("사진에 저장됨", "Saved to Photos")
        case .failed(let reason):
            return reason
        case .idle:
            break
        }
        if !isManual && isLoading {
            return language.text("기록에서 도시를 찾는 중입니다.", "Finding cities in your records.")
        }
        guard let trip, trip.isRenderable else {
            return isManual
                ? language.text("도시를 두 곳 이상 넣어 주세요.", "Add at least two cities.")
                : language.text(
                    "이 기간에는 두 도시 이상 다닌 기록이 없습니다. 직접 입력으로 만들 수 있습니다.",
                    "No trip between two or more cities in this period. You can enter one manually."
                )
        }
        return language.text(
            "도시를 이어 그린 세로 영상을 만듭니다. 지도는 앱에 든 Natural Earth 자료로 그립니다.",
            "Makes a vertical video connecting your cities, drawn from Natural Earth map data in the app."
        )
    }

    @ViewBuilder
    private var buttons: some View {
        switch phase {
        case .rendering, .saving:
            EmptyView()
        case .saved:
            Label(language.text("사진에 저장됨", "Saved to Photos"), systemImage: "checkmark.circle.fill")
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(15)), weight: .bold))
                .foregroundStyle(Color.tpAccent)
        case .idle, .failed:
            Button(action: openEditor) {
                Label(
                    isManual ? language.text("경로 편집", "Edit route") : language.text("직접 고치기", "Edit as manual trip"),
                    systemImage: "list.bullet"
                )
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(15)), weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
                .foregroundStyle(Color.tpInk)
                .background(Color.tpSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            Button(action: start) {
                Label(language.text("영상 만들기", "Make video"), systemImage: "film")
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(16)), weight: .bold))
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .foregroundStyle(.white)
                    .background(Color.tpPrimaryFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!(trip?.isRenderable ?? false))
            .opacity(trip?.isRenderable ?? false ? 1 : 0.5)
        }
    }

    /// 기록에서 뽑은 여행을 고치려면 직접 입력 초안으로 옮겨 편집한다. 원본 기록은 그대로다.
    private func openEditor() {
        if !isManual, let recordTrip, recordTrip.isRenderable {
            manualTrip = recordTrip
            sourceRaw = "manual"
        }
        isEditing = true
    }

    // MARK: - 기록 읽기

    private func loadRecords() async {
        if case .failed = phase { phase = .idle }
        guard !isManual else { return }
        recordTrip = nil
        isLoading = true
        loadPercent = 0
        defer { isLoading = false }
        let span = span
        guard let loaded = await MapHomeRangeSampleLoader.read(model: model, span: span, progress: { loadPercent = $0 }) else { return }
        let stays: [TravelMapTripExtractor.Stay] = model.snapshot.places.compactMap { stay in
            guard let point = stay.point, stay.span.end > span.start, stay.span.start < span.end else { return nil }
            return TravelMapTripExtractor.Stay(span: stay.span, latitude: point.latitude, longitude: point.longitude, name: stay.displayName)
        }
        let moves: [TravelMapTripExtractor.Move] = model.snapshot.travel.compactMap { move in
            guard move.span.end > span.start, move.span.start < span.end else { return nil }
            return TravelMapTripExtractor.Move(span: move.span, mode: move.mode, meters: move.distanceMeters)
        }
        let trip = await Self.extract(samples: loaded.samples, stays: stays, moves: moves, language: language)
        guard !Task.isCancelled else { return }
        recordTrip = trip
    }

    /// 주 스레드 밖에서 도시를 뽑는다.
    private nonisolated static func extract(
        samples: [MapHomeRangeTripPlan.Sample],
        stays: [TravelMapTripExtractor.Stay],
        moves: [TravelMapTripExtractor.Move],
        language: MapHomeLanguage
    ) async -> TravelMapTrip {
        TravelMapTripExtractor.extract(samples: samples, stays: stays, moves: moves, catalog: .bundled, language: language)
    }

    // MARK: - 렌더

    private func start() {
        guard let trip, trip.isRenderable else { return }
        let renderer = TravelMapVideoRenderer(trip: trip, language: language, palette: .current)
        renderer.music = MapHomePlaybackMusicTrack.stored(musicRaw)?.url
        progress = 0
        phase = .rendering
        task = Task { await run(renderer) }
    }

    private func run(_ renderer: TravelMapVideoRenderer) async {
        do {
            let url = try await renderer.render { value in
                if value != progress { progress = value }
            }
            defer { try? FileManager.default.removeItem(at: url) }
            try Task.checkCancellation()
            phase = .saving
            let saved = await MapHomePlaybackVideoRenderer.saveToPhotos(url)
            phase = saved ? .saved : .failed(language.text("사진 저장 권한이 필요합니다.", "Photo saving permission is needed."))
        } catch is CancellationError {
            phase = .idle
        } catch {
            phase = .failed(language.text("영상을 만들지 못했습니다.", "Could not make the video."))
        }
        task = nil
    }
}
