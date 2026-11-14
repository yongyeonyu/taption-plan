import SwiftUI

/// GPS 로그만 GPX로 내보내 공유한다(PLN1111A01). 날짜 기간을 고르면 미리보기가 나오고 공유할 수 있다(GPV1114A01).
struct GPXExportCard: View {
    let model: AppModel
    let language: MapHomeLanguage
    @State private var from = Date.now
    @State private var to = Date.now
    @State private var status = ""
    @State private var file: URL?
    @State private var preview: GPXTrackExport.Preview?

    private struct Range: Equatable { var from: Date; var to: Date }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                DatePicker(language.text("시작", "From"), selection: $from, in: ...Date.now, displayedComponents: .date)
                Text(verbatim: "–").foregroundStyle(.secondary)
                DatePicker(language.text("끝", "To"), selection: $to, in: ...Date.now, displayedComponents: .date)
            }
            .labelsHidden()
            .datePickerStyle(.compact)
            if let preview, preview.pointCount > 0 {
                GPXTrackPreview(track: preview.track)
                    .frame(height: 130)
                    .background(Color.tpReferenceBlue.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                Text(verbatim: summary(preview))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(11.5)), weight: .semibold))
                    .monospacedDigit()
            }
            if let file {
                ShareLink(item: file) {
                    Label(language.text("공유", "Share"), systemImage: "square.and.arrow.up")
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .semibold))
                }
                .buttonStyle(.bordered)
                .tint(Color.tpReferenceBlue)
            }
            Text(status.isEmpty
                 ? language.text("위치 점(위도·경도·고도·시각)만 담아요. 활동·건강·가계부·메모는 들어가지 않고, 다른 지도·운동 앱에서 열 수 있어요.",
                                 "Contains location points only (latitude, longitude, altitude, time). No activities, health, ledger or memos. Opens in other map and fitness apps.")
                 : status)
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(10.5)), weight: .medium))
                .foregroundStyle(.secondary)
        }
        .task(id: Range(from: from, to: to)) { await load() }
    }

    /// 「2,104 · 12.3 km · 11. 13. 08:02 – 11. 14. 01:17」
    private func summary(_ preview: GPXTrackExport.Preview) -> String {
        let distance = Measurement(value: preview.meters / 1_000, unit: UnitLength.kilometers)
            .formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(1))))
        let style = Date.FormatStyle().month(.defaultDigits).day().hour().minute()
        let times = [preview.first, preview.last].compactMap { $0?.formatted(style) }.joined(separator: " – ")
        return [preview.pointCount.formatted(), distance, times].joined(separator: " · ")
    }

    @MainActor
    private func load() async {
        // 날짜를 돌리는 동안에는 만들지 않는다.
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return }
        file = nil
        preview = nil
        status = language.text("만드는 중…", "Preparing…")
        do {
            let result = try await model.exportGPX(from: from, to: to)
            guard !Task.isCancelled else { return }
            guard result.preview.pointCount > 0 else {
                status = language.text("이 기간에는 기기에 남은 위치 기록이 없어요.", "No location records on this device for that period.")
                return
            }
            preview = result.preview
            file = result.url
            status = language.text("위치 점 \(result.preview.pointCount)개를 담았어요. 공유를 눌러 보내세요.", "\(result.preview.pointCount) location points ready. Tap Share to send.")
        } catch {
            if !Task.isCancelled { status = language.text("파일을 만들지 못했어요.", "Couldn't create the file.") }
        }
    }
}

/// 고른 기간의 자취를 선으로만 그린다. 지도 바탕은 없다.
struct GPXTrackPreview: View {
    let track: [[SIMD2<Double>]]

    var body: some View {
        Canvas { context, size in
            let all = track.flatMap { $0 }
            guard let first = all.first else { return }
            var west = first.x, east = first.x, south = first.y, north = first.y
            for point in all { west = min(west, point.x); east = max(east, point.x); south = min(south, point.y); north = max(north, point.y) }
            // 위도에 따라 경도 간격이 좁아지는 만큼 가로를 줄인다.
            let squeeze = cos((south + north) / 2 * .pi / 180)
            let width = max((east - west) * squeeze, 0.0005), height = max(north - south, 0.0005)
            let inset: CGFloat = 12
            let scale = min((size.width - inset * 2) / width, (size.height - inset * 2) / height)
            func spot(_ point: SIMD2<Double>) -> CGPoint {
                CGPoint(x: size.width / 2 + ((point.x - (west + east) / 2) * squeeze) * scale,
                        y: size.height / 2 - (point.y - (south + north) / 2) * scale)
            }
            for part in track where !part.isEmpty {
                var path = Path()
                path.addLines(part.map(spot))
                context.stroke(path, with: .color(Color.tpReferenceBlue), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                if part.count == 1 { context.fill(Path(ellipseIn: CGRect(origin: spot(part[0]), size: .zero).insetBy(dx: -2, dy: -2)), with: .color(Color.tpReferenceBlue)) }
            }
            if let last = all.last { context.fill(Path(ellipseIn: CGRect(origin: spot(last), size: .zero).insetBy(dx: -4, dy: -4)), with: .color(Color.tpReferenceRose)) }
        }
        .accessibilityHidden(true)
    }
}

/// 메뉴의 「GPS 및 센서 데이터」 줄. 누르면 아래로 GPS 로그 보내기가 펼쳐진다(GPV1114A01).
struct GPSDataMenuSection<Row: View>: View {
    let model: AppModel
    let language: MapHomeLanguage
    @ViewBuilder var row: Row
    @State private var isOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation(.snappy(duration: 0.2)) { isOpen.toggle() } } label: {
                row.overlay(alignment: .topTrailing) {
                    Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                        .font(.system(size: TaptionType.scaled(TaptionType.snapped(10)), weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(12)
                }
            }
            .buttonStyle(.plain)
            if isOpen {
                VStack(alignment: .leading, spacing: 6) {
                    Text(language.text("GPS 로그", "GPS log"))
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .semibold))
                    GPXExportCard(model: model, language: language)
                }
                .padding(12)
                .background(Color.tpReferenceRose.opacity(0.055), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }
}
