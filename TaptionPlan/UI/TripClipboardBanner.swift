import SwiftUI

/// AI 앱에서 여행 JSON을 복사해 돌아오면 배너로 가져오기를 권한다(TRP1110A03).
/// 클립보드를 직접 읽으면 iOS가 매번 붙여넣기 허용 창을 띄우므로 내용은 읽지 않는다.
/// 프롬프트를 복사한 뒤 클립보드가 바뀌었는지(changeCount)만 보고, 붙여넣기는 시스템 버튼으로 한다.
enum TripClipboardWatch {
    private static let changeCountKey = "tripImportPromptChangeCount"
    private static let startedKey = "tripImportPromptStartedAt"
    /// AI와 계획을 세우는 데 이만큼까지는 기다린다.
    static let window: TimeInterval = 6 * 3_600

    /// 프롬프트를 복사한 직후 부른다.
    static func promptCopied(now: Date = .now, defaults: UserDefaults = .standard) {
        defaults.set(UIPasteboard.general.changeCount, forKey: changeCountKey)
        defaults.set(now.timeIntervalSinceReferenceDate, forKey: startedKey)
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: changeCountKey)
        defaults.removeObject(forKey: startedKey)
    }

    static func shouldOffer(currentChangeCount: Int, hasStrings: Bool, now: Date = .now, defaults: UserDefaults = .standard) -> Bool {
        guard hasStrings, let started = defaults.object(forKey: startedKey) as? Double,
              now.timeIntervalSinceReferenceDate - started <= window,
              let copied = defaults.object(forKey: changeCountKey) as? Int else { return false }
        return currentChangeCount != copied
    }
}

struct TripClipboardBanner: View {
    let language: MapHomeLanguage
    let onPaste: (String) -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles").foregroundStyle(Color.tpInk)
            Text(language.text("AI에서 복사한 여행 계획을 가져올까요?", "Import the trip plan you copied from the AI?"))
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.label), weight: .semibold))
                .foregroundStyle(Color.tpInk)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            PasteButton(payloadType: String.self) { strings in
                guard let text = strings.first else { return }
                Task { @MainActor in onPaste(text) }
            }
            .labelStyle(.iconOnly)
            .buttonBorderShape(.capsule)
            Button(action: onDismiss) {
                Image(systemName: "xmark").frame(width: 32, height: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.tpSecondary)
            .accessibilityLabel(language.text("닫기", "Close"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color.tpSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
        .padding(.horizontal, 16)
    }
}

extension MapHomeView {
    func refreshTripClipboardOffer() {
        let offer = TripClipboardWatch.shouldOffer(
            currentChangeCount: UIPasteboard.general.changeCount,
            hasStrings: UIPasteboard.general.hasStrings
        )
        if offer != isTripClipboardOfferVisible { isTripClipboardOfferVisible = offer }
    }

    @ViewBuilder var tripClipboardBanner: some View {
        if isTripClipboardOfferVisible {
            TripClipboardBanner(language: language) { text in
                isTripClipboardOfferVisible = false
                pastedTripText = text
                isTravelMode = true
                isTripImportPresented = true
            } onDismiss: {
                isTripClipboardOfferVisible = false
                TripClipboardWatch.clear()
            }
            .padding(.top, 70)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
