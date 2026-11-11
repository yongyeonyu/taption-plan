import SwiftUI

/// 「비밀번호를 잊었어요」: Face ID(안 되면 기기 암호)를 통과하면 보관한 백업 비밀번호를 보여 준다(BKP1110A02).
struct BackupPasswordForgotView: View {
    let model: AppModel
    let language: MapHomeLanguage
    /// 입력 칸이 있는 곳에서만 넘긴다.
    var fill: ((String) -> Void)?
    @Environment(\.scenePhase) private var scenePhase
    @State private var reveal: BackupPasswordReveal?
    @State private var isChecking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(language.text("비밀번호를 잊었어요", "Forgot password")) { check() }
                .buttonStyle(.borderless)
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .medium))
                .disabled(isChecking)
                .accessibilityIdentifier("backupPasswordForgot")
            switch reveal {
            case .revealed(let password): revealed(password)
            case .some(let other): note(Self.message(for: other, language: language))
            case nil: EmptyView()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active, reveal != nil { reveal = nil }
        }
    }

    private func revealed(_ password: String) -> some View {
        HStack(spacing: 10) {
            Text(password)
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(17)), weight: .semibold).monospacedDigit())
                .privacySensitive()
                .accessibilityIdentifier("backupPasswordRevealed")
            if let fill {
                Button(language.text("칸에 채우기", "Fill in")) {
                    fill(password)
                    reveal = nil
                }
            }
            Button(language.text("가리기", "Hide")) { reveal = nil }
        }
        .buttonStyle(.bordered)
        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .medium))
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .medium))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func check() {
        guard !isChecking else { return }
        isChecking = true
        Task { @MainActor in
            reveal = await model.revealBackupPassword()
            isChecking = false
        }
    }

    static func message(for reveal: BackupPasswordReveal, language: MapHomeLanguage) -> String {
        switch reveal {
        case .revealed:
            ""
        case .nothingStored:
            language.text(
                "이 기기에는 보관된 비밀번호가 없습니다. 비밀번호 없이는 백업을 열 수 없습니다.",
                "This device has no saved password. Backups cannot be opened without it."
            )
        case .passcodeNotSet:
            language.text(
                "기기 암호가 있어야 볼 수 있습니다. 설정 앱에서 기기 암호를 켠 뒤 다시 시도해 주세요.",
                "A device passcode is required to show it. Turn on a passcode in Settings and try again."
            )
        case .denied:
            language.text("본인 확인을 완료하지 못했습니다.", "Identity check was not completed.")
        }
    }
}
