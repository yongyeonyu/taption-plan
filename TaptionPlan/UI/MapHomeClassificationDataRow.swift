import SwiftUI

/// 설정 › 내 데이터의 「분류 개선 데이터 수집」(MSC1119A01). 기본 꺼짐. 켜고 끄는 곳은 여기 하나뿐이다.
/// 값은 `.task`로 한 번 읽고 토글·지우기·내보내기 뒤에만 다시 읽는다. `body`에서 매번 파일을 읽지 않는다.
struct MapHomeClassificationDataRow: View {
    let model: AppModel
    let language: MapHomeLanguage
    @State private var isOn = false
    @State private var total = 0
    @State private var exportFile: ExportFile?
    @State private var isDeleteConfirmationPresented = false

    private struct ExportFile: Identifiable {
        let id = UUID()
        let url: URL
    }

    private var collector: MisclassificationCollector { .live }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(language.text("분류 개선 데이터 수집", "Collect classification improvement data"), isOn: Binding(
                get: { isOn },
                set: { value in
                    isOn = value
                    collector.setEnabled(value)
                    reload()
                }
            ))
            .tint(Color.tpReferenceMint)
            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .semibold))
            .accessibilityIdentifier("classificationDataToggle")
            Text(language.text(
                "켜면 분류를 고칠 때마다 시간대·길이·평균 속도·걸음 수·바꾸기 전 분류 → 바꾼 분류·확신도만 기기에 쌓아요. 좌표·장소 이름·일정 제목·날짜는 넣지 않아요. 자동으로 보내지 않고, 「내보내기」를 누를 때만 파일로 나가요.",
                "When on, each time you fix a classification only the time of day, length, average speed, step count and the classification before → after with its confidence are kept on this device. Coordinates, place names, event titles and dates are never included. Nothing is sent automatically; a file leaves only when you tap Export."
            ))
            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .medium))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            if !isOn, total > 0 {
                Text(language.text(
                    "끄면 더 모으지 않아요. 이미 모은 \(total)건은 그대로 두고, 지우려면 「지우기」를 누르세요.",
                    "Turning it off stops collecting. The \(total) already collected stay until you tap Delete."
                ))
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Text(language.text("기기에 \(total)건 모음", "\(total) collected on this device"))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .medium))
                    .foregroundStyle(Color.tpSecondary)
                    .accessibilityIdentifier("classificationDataCount")
                Spacer(minLength: 0)
                Button(language.text("내보내기", "Export")) { export() }
                    .buttonStyle(.bordered)
                    .tint(Color.tpReferenceBlue)
                    .disabled(total == 0)
                Button(language.text("지우기", "Delete"), role: .destructive) { isDeleteConfirmationPresented = true }
                    .buttonStyle(.bordered)
                    .disabled(total == 0)
            }
            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .medium))
        }
        .task { reload() }
        .sheet(item: $exportFile) { file in
            MisclassificationShareSheet(items: [file.url])
                .onDisappear { try? FileManager.default.removeItem(at: file.url) }
        }
        .confirmationDialog(
            language.text("모은 분류 개선 데이터를 지울까요?", "Delete the collected classification data?"),
            isPresented: $isDeleteConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button(language.text("지우기", "Delete"), role: .destructive) {
                collector.removeAll()
                reload()
            }
            Button(language.text("취소", "Cancel"), role: .cancel) {}
        } message: {
            Text(language.text("되돌릴 수 없어요.", "This can't be undone."))
        }
    }

    private func reload() {
        let live = collector
        isOn = live.isEnabled
        total = live.summary().total
    }

    /// 3절의 표본만 든 JSON을 임시 파일로 써서 공유 시트로 넘긴다. 시트가 닫히면 파일을 지운다.
    private func export() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("misclassification-samples.json")
        do {
            try collector.exportPayload().write(to: url, options: .atomic)
            exportFile = ExportFile(url: url)
        } catch {
            model.userFacingError = language.text("내보낼 파일을 만들지 못했습니다.", "Couldn't create the export file.")
        }
    }
}

private struct MisclassificationShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
