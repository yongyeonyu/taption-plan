import SwiftUI

/// 도착 카드는 이 작은 뷰만 지켜본다. 지도 화면 본문은 카드 때문에 다시 계산되지 않는다(ARC1114A14).
struct ArrivalCardHost: View {
    let model: AppModel
    let language: MapHomeLanguage
    @Environment(\.scenePhase) private var scenePhase
    private var manager: ArrivalCardManager { .shared }

    var body: some View {
        ZStack {
            if let card = manager.card {
                ArrivalCardView(card: card, language: language, checked: manager.checked, onToggle: { manager.toggle($0) }, onClose: { manager.dismiss() })
                    .padding(.top, 70)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: manager.card?.id)
        .task(id: model.isBootstrapped) { manager.presentPending(model: model) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { manager.presentPending(model: model) }
        }
    }
}

/// 지금 도착한 일정 장소 카드: 이름·시각·메모·세부 계획 체크·예상 지출. 건드리지 않으면 1분 뒤 닫힌다.
struct ArrivalCardView: View {
    let card: ArrivalCard
    let language: MapHomeLanguage
    let checked: Set<String>
    let onToggle: (String) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "mappin.circle.fill").foregroundStyle(Color.tpAccent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(language.text("지금 도착한 곳", "You've arrived"))
                        .font(font(11, .semibold))
                        .foregroundStyle(Color.tpSecondary)
                    Text(verbatim: card.title).font(font(16, .bold)).lineLimit(2)
                    if let timeText { Text(verbatim: timeText).font(font(12, .medium)).foregroundStyle(Color.tpSecondary) }
                }
                Spacer(minLength: 0)
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(language.text("닫기", "Close"))
            }
            if let note = card.note {
                Label { Text(verbatim: note).lineLimit(6) } icon: { Image(systemName: "note.text") }
                    .font(font(13, .medium))
            }
            if !card.checklist.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(card.checklist) { item in checkRow(item) }
                }
            }
            if let spend = card.plannedSpendKRW {
                moneyRow(language.text("이곳 예상 지출", "Planned spend here"), spend, symbol: "wonsign.circle")
            }
            if let budget = card.tripBudgetKRW {
                moneyRow(language.text("여행 예산", "Trip budget"), budget, symbol: "suitcase")
            }
        }
        .foregroundStyle(Color.tpInk)
        .padding(14)
        .frame(maxWidth: 420, alignment: .leading)
        .mapHomeGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, 16)
        .task(id: "\(card.id)|\(checked.count)") {
            try? await Task.sleep(for: .seconds(60))
            if !Task.isCancelled { onClose() }
        }
    }

    private var timeText: String? {
        guard let start = card.start else { return nil }
        let zone = card.offsetSeconds.flatMap { TimeZone(secondsFromGMT: $0) } ?? .current
        let style = Date.FormatStyle(locale: language.locale, timeZone: zone).hour().minute()
        guard let end = card.end, end > start else { return start.formatted(style) }
        return "\(start.formatted(style)) – \(end.formatted(style))"
    }

    private func checkRow(_ item: ArrivalCard.CheckItem) -> some View {
        let isDone = checked.contains(item.id)
        return Button { onToggle(item.id) } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isDone ? Color.tpAccent : Color.tpSecondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: item.title).font(font(13, .semibold)).strikethrough(isDone)
                    if let note = item.note {
                        Text(verbatim: note).font(font(11, .regular)).foregroundStyle(Color.tpSecondary).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(isDone ? language.text("완료", "Done") : language.text("미완료", "Not done"))
    }

    private func moneyRow(_ title: String, _ amount: Double, symbol: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(Color.tpSecondary)
            Text(title).foregroundStyle(Color.tpSecondary)
            Spacer(minLength: 8)
            Text(verbatim: LedgerMoney.text(amount, language: language))
        }
        .font(font(13, .semibold))
    }

    private func font(_ size: CGFloat, _ weight: Font.Weight) -> Font {
        .taptionFixed(size: TaptionType.scaled(TaptionType.snapped(size)), weight: weight)
    }
}

/// 알림 설정의 「일정 장소 도착 카드」 스위치.
struct ArrivalCardSettingRow: View {
    let language: MapHomeLanguage
    @AppStorage(ArrivalCardManager.enabledKey) private var isEnabled = true

    var body: some View {
        Toggle(isOn: $isEnabled) {
            HStack(spacing: 10) {
                Image(systemName: "mappin.circle")
                    .foregroundStyle(Color.tpAccent)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(language.text("일정 장소 도착 카드", "Arrival card for planned places"))
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(14)), weight: .semibold))
                    Text(language.text(
                        "여행 일정에 넣은 곳에 도착하면 메모·세부 계획·예상 지출을 보여요. 알림과 위치를 허용했으면 앱을 닫아 두어도 그날 일정 장소에서 알림이 올 수 있고, 일정마다 한 번만 떠요.",
                        "Shows notes, sub-plans and planned spend when you reach a place in your trip plan. With notifications and location allowed, today's planned places can alert you even when the app is closed, once per plan."
                    ))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(11))))
                    .foregroundStyle(Color.tpSecondary)
                }
            }
        }
        .tint(Color.tpAccent)
        .onChange(of: isEnabled) { _, _ in ArrivalCardManager.shared.scheduleAlertSync() }
        .padding(.vertical, 8)
        .padding(.horizontal, 14)
        .background(Color.tpSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
