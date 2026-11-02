import SwiftUI

/// 하루 재생을 영상으로 만들어 사진 앱에 저장하는 시트(VID1029A01).
/// 입력은 부모가 `makeRenderer`로 넘긴다. 시트는 진행·취소·결과만 맡는다.
struct MapHomePlaybackVideoSheet: View {
    let model: AppModel
    let language: MapHomeLanguage
    let makeRenderer: @MainActor () -> MapHomePlaybackVideoRenderer?

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
    }

    private var message: String {
        switch phase {
        case .idle:
            language.text("하루 재생을 60fps 영상으로 그립니다. 끊김 없이 저장됩니다.", "Renders the day at 60 fps with no dropped frames.")
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
        }
    }

    private func start() {
        guard let renderer = makeRenderer() else {
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
        } catch {
            phase = .failed(language.text("영상을 만들지 못했습니다.", "Could not make the video."))
        }
        task = nil
    }
}
