import SwiftUI
import TaptionPlanCore

/// 「서버로 보내기」 미리보기·확인 시트(MSC1119B01). 건수와 실제 내용을 보여 주고, 「보내기」를 눌러야만 올린다.
/// 보낸 표본은 기기에서 비운다(`MisclassificationUploader` 머리 주석). 실패하면 표본은 그대로 남는다.
struct MapHomeClassificationUploadSheet: View {
    let language: MapHomeLanguage
    let collector: MisclassificationCollector
    let onFinished: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var preview: MisclassificationUploader.Preview?
    @State private var isSending = false
    @State private var result: MisclassificationUploader.Result?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let result { resultView(result) } else if let preview { previewView(preview) }
                }
                .padding(16)
            }
            .navigationTitle(language.text("서버로 보내기", "Send to server"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(result == nil ? language.text("취소", "Cancel") : language.text("닫기", "Close")) { close() }
                        .disabled(isSending)
                }
            }
        }
        .interactiveDismissDisabled(isSending)
        .task { preview = MisclassificationUploader.preview(collector.samples(), ruleVersion: ClassificationRules.version) }
    }

    private func previewView(_ preview: MisclassificationUploader.Preview) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(language.text("\(preview.total)건을 보내요", "Sending \(preview.total) samples"))
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(17)), weight: .bold))
                .accessibilityIdentifier("classificationUploadCount")
            Text(language.text(
                "활동 \(preview.activity)건 · 이동 \(preview.travel)건 · 규칙 \(preview.ruleVersion)",
                "\(preview.activity) activity · \(preview.travel) travel · rules \(preview.ruleVersion)"
            ))
            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .medium))
            .foregroundStyle(.secondary)
            Text(language.text(
                "표본에는 시간대·요일·길이·평균 속도·걸음 수·바꾸기 전 분류 → 바꾼 분류·확신도만 있어요. 좌표·장소 이름·일정 제목·날짜·이름은 없어요. 보낸 표본은 이 기기에서 지워요. 설정의 「지우기」와 달리 서버에는 남아 분류 규칙을 고치는 데 쓰고, 1년 뒤 지워요.",
                "Each sample has only the time of day, weekday, length, average speed, step count and the classification before → after with its confidence. No coordinates, place names, event titles, dates or names. Sent samples are removed from this device. Unlike Delete in settings, the server keeps them to improve the classification rules and deletes them after one year."
            ))
            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .medium))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            if !preview.lines.isEmpty {
                Text(language.text("최근 표본", "Latest samples"))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .semibold))
                ForEach(preview.lines, id: \.self) { line in
                    Text(line).font(.system(size: 12, design: .monospaced)).foregroundStyle(Color.tpSecondary)
                }
            }
            if !preview.example.isEmpty {
                Text(language.text("서버로 가는 표본 한 건의 실제 모습", "What one sample looks like on the wire"))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .semibold))
                Text(preview.example)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.tpSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button { Task { await send() } } label: {
                HStack {
                    if isSending { ProgressView() }
                    Text(isSending ? language.text("보내는 중…", "Sending…") : language.text("\(preview.total)건 보내기", "Send \(preview.total)"))
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.tpReferenceBlue)
            .disabled(isSending || preview.total == 0)
            .accessibilityIdentifier("classificationUploadConfirm")
        }
    }

    private func resultView(_ result: MisclassificationUploader.Result) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if result.sent > 0 {
                Text(language.text("\(result.sent)건을 보냈어요", "Sent \(result.sent) samples"))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(17)), weight: .bold))
                Text(language.text(
                    "새로 \(result.accepted)건 · 이미 있음 \(result.duplicates)건 · 받지 않음 \(result.rejected)건. 보낸 표본은 이 기기에서 지웠어요.",
                    "\(result.accepted) new · \(result.duplicates) already there · \(result.rejected) not accepted. Sent samples were removed from this device."
                ))
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .medium))
                .foregroundStyle(.secondary)
            }
            if let failure = result.failure {
                Text(message(failure))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .semibold))
                    .foregroundStyle(Color.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("classificationUploadError")
            }
        }
    }

    private func message(_ failure: MisclassificationUploader.Failure) -> String {
        switch failure {
        case .disabled: language.text("분류 개선 데이터 수집이 꺼져 있어 보내지 않았어요.", "Collection is off, so nothing was sent.")
        case .locked: language.text("사생활 잠금 중에는 보내지 않아요. 잠금을 푼 뒤 다시 눌러 주세요.", "Nothing is sent while privacy lock is on. Unlock and try again.")
        case .notReady: language.text("서버에 연결하지 못했어요. 남은 표본은 그대로 있으니 잠시 뒤 다시 눌러 주세요.", "Couldn't reach the server. Your remaining samples are kept; try again later.")
        case .offline: language.text("인터넷에 연결되지 않았어요. 남은 표본은 그대로 있으니 연결된 뒤 다시 눌러 주세요.", "You're offline. Your remaining samples are kept; try again when connected.")
        case .dailyLimit: language.text("오늘 보낼 수 있는 양(2,000건)을 넘었어요. 남은 표본은 그대로 있으니 내일 다시 눌러 주세요.", "You've hit today's limit (2,000 samples). The rest are kept; try again tomorrow.")
        case .server(let status): language.text("서버가 받지 못했어요(\(status)). 남은 표본은 그대로 있어요.", "The server couldn't accept them (\(status)). Your remaining samples are kept.")
        }
    }

    private func send() async {
        isSending = true
        let outcome = await MisclassificationUploader.send(collector: collector)
        isSending = false
        result = outcome
        if outcome.removed > 0 { onFinished() }
    }

    private func close() {
        onFinished()
        dismiss()
    }
}
