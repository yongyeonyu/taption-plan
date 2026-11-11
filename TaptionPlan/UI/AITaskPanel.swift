import SwiftUI

/// 메모 패널 「AI」 탭(AIQ1111A01): AI에게 맡긴 일과 상태(대기·처리중·완료·실패), 끝난 것 지우기.
/// 앱이 못 읽은 결제 문자·영수증, 메모 다듬기처럼 AI가 처리할 것이 여기 쌓이고, 처리됐는지 이 목록으로 본다.
struct AITaskPanel: View {
    let language: MapHomeLanguage

    @State private var tasks: [AITaskQueue.Task] = []
    @State private var isLoading = false
    @State private var inbox: [PaymentInbox.Item] = []
    @State private var opened: PaymentInbox.Item?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PaymentInboxList(language: language, items: inbox) { opened = $0 }
            if !MemoPolishQueue.hasConnection() {
                note(language.text("AI 연결이 없어요. 메뉴 › AI 연결에서 연결하면 앱이 못한 일을 AI가 처리해요.",
                                   "No AI is connected. Connect one in Menu › AI connection to let it handle what the app couldn't."))
            } else if tasks.isEmpty {
                note(isLoading ? language.text("불러오는 중…", "Loading…") : language.text("AI에게 맡긴 일이 없어요.", "Nothing is waiting for your AI."))
            }
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(tasks) { row($0) }
                }
            }
            .frame(maxHeight: 320)
            .refreshable { await reload() }
            if tasks.contains(where: { $0.status == .done || $0.status == .failed }) {
                Button {
                    Task {
                        if await AITaskQueue.deleteFinished() { tasks = Self.merged() }
                    }
                } label: {
                    Label(language.text("끝난 일 지우기", "Clear finished"), systemImage: "trash")
                        .font(.taptionStyle(.caption, weight: .semibold))
                        .foregroundStyle(Color.tpSecondary)
                }
                .buttonStyle(.plain)
            }
        }
        .task {
            tasks = Self.merged()
            inbox = PaymentInbox.items().reversed()
            await reload()
        }
        .sheet(item: $opened, onDismiss: { inbox = PaymentInbox.items().reversed(); tasks = Self.merged() }) {
            PaymentInboxDetail(language: language, item: $0)
        }
    }

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        await AITaskQueue.refresh()
        let next = Self.merged()
        if next != tasks { tasks = next }
    }

    /// 서버 목록 + 아직 못 올린 항목 + 메모 다듬기 목록(따로 `/polish`로 간다).
    private static func merged() -> [AITaskQueue.Task] {
        let pending = AITaskQueue.pendingUploads().map {
            AITaskQueue.Task(id: $0.id, kind: $0.kind, text: $0.text, date: $0.date, status: .waiting)
        }
        let polish = MemoPolishQueue.items().map {
            AITaskQueue.Task(id: "polish-" + $0.memoID.uuidString, kind: .memoPolish, text: $0.text, date: $0.date, status: .waiting)
        }
        let order: [AITaskQueue.Status: Int] = [.processing: 0, .waiting: 1, .failed: 2, .done: 3]
        return (pending + polish + AITaskQueue.cached()).sorted {
            (order[$0.status] ?? 9, -($0.createdAt?.timeIntervalSince1970 ?? .infinity))
                < (order[$1.status] ?? 9, -($1.createdAt?.timeIntervalSince1970 ?? .infinity))
        }
    }

    private func row(_ task: AITaskQueue.Task) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: Self.symbol(task.kind))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.tpAccent)
                .frame(width: 26, height: 26)
                .background(Color.white.opacity(0.9), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title(task.kind))
                        .font(.taptionStyle(.subheadline, weight: .medium))
                        .foregroundStyle(Color.tpInk)
                    Spacer(minLength: 0)
                    statusChip(task.status)
                }
                if let detail = task.result ?? task.reason ?? task.text {
                    Text(detail)
                        .font(.taptionStyle(.caption))
                        .foregroundStyle(task.status == .failed ? Color.tpHoliday : Color.tpSecondary)
                        .lineLimit(3)
                }
                if let date = task.updatedAt ?? task.createdAt {
                    Text(date.formatted(date: .abbreviated, time: .shortened))
                        .font(.taptionStyle(.caption2))
                        .foregroundStyle(Color.tpSecondary)
                }
            }
        }
        .padding(10)
        .background(Color.tpCard.opacity(0.9), in: RoundedRectangle(cornerRadius: TaptionCorner.medium, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: TaptionCorner.medium, style: .continuous).stroke(Color.tpBorder, lineWidth: TaptionBorder.width) }
    }

    private func statusChip(_ status: AITaskQueue.Status) -> some View {
        let (text, color): (String, Color) = switch status {
        case .waiting: (language.text("대기", "Waiting"), Color.tpSecondary)
        case .processing: (language.text("처리중", "Working"), Color.tpReferenceBlue)
        case .done: (language.text("완료", "Done"), Color.tpReferenceMint)
        case .failed: (language.text("실패", "Failed"), Color.tpHoliday)
        }
        return Text(text)
            .font(.taptionStyle(.caption2, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color, in: Capsule())
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.taptionStyle(.caption))
            .foregroundStyle(Color.tpSecondary)
            .padding(.horizontal, 4)
    }

    private func title(_ kind: AITaskQueue.Kind) -> String {
        switch kind {
        case .paymentText: language.text("결제 문자 확인", "Payment text")
        case .receiptText: language.text("영수증 확인", "Receipt")
        case .memoPolish: language.text("메모 다듬기", "Polish memo")
        case .routeCheck: language.text("경로 확인", "Route check")
        case .fareCheck: language.text("교통비 확인", "Fare check")
        case .mergeReview: language.text("조각 합침 검토", "Merge review")
        case .stayPlace: language.text("머문 장소 확인", "Stay place")
        case .paymentRule: language.text("결제 문자 규칙 요청", "Payment rule request")
        case .other: language.text("기타 확인", "Other")
        }
    }

    private static func symbol(_ kind: AITaskQueue.Kind) -> String {
        switch kind {
        case .paymentText: "message"
        case .receiptText: "doc.text.viewfinder"
        case .memoPolish: "wand.and.stars"
        case .routeCheck: "point.topleft.down.to.point.bottomright.curvepath"
        case .fareCheck: "creditcard"
        case .mergeReview: "rectangle.compress.vertical"
        case .stayPlace: "mappin.and.ellipse"
        case .paymentRule: "text.badge.plus"
        case .other: "questionmark.bubble"
        }
    }
}
