import SwiftUI
import TaptionPlanStore

/// 여행 중 오늘 카드(TVZ1116C01): 아래 판이 내려 있을 때 「다음: …」 한 줄 대신 지금·다음·남은 돈과 지난 일정 확정을 보인다.
struct TravelTodayCard: View {
    @Bindable var model: AppModel
    let entry: TravelTripDirectory.Entry
    let blocks: [TravelPlanTableModel.Block]
    let travelMinutes: [String: Int]
    let sheet: LedgerTripSheet?
    let language: MapHomeLanguage
    let onExpense: () -> Void
    let onAddStop: () -> Void
    let onReality: () -> Void
    let onRaise: () -> Void

    @State private var isReviewing = false

    var body: some View {
        // 남은 시간은 분이 바뀔 때만 다시 그린다.
        TimelineView(.everyMinute) { context in
            content(TravelTodayText.board(model: model, tripID: entry.id, blocks: blocks, travelMinutes: travelMinutes, now: context.date))
        }
        .sheet(isPresented: $isReviewing) {
            TravelTodayReviewSheet(model: model, tripID: entry.id, blocks: blocks, language: language)
        }
    }

    private func content(_ board: TravelTodayBoard) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: onRaise) {
                HStack(spacing: 6) {
                    Text(heading).font(.footnote.weight(.semibold)).opacity(0.8)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up").font(.footnote.weight(.semibold)).opacity(0.6)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(language.text("계획표 올리기", "Open plan table"))
            if board.isEmpty {
                HStack(spacing: 8) {
                    Text(language.text("오늘 일정이 없습니다", "No plans today")).font(.subheadline.weight(.medium))
                    Spacer(minLength: 0)
                    TravelTodayChip(title: language.text("곳 더하기", "Add a stop"), symbol: "mappin.and.ellipse", isFilled: true, action: onAddStop)
                }
            } else {
                plans(board)
            }
            if let review = board.reviews.last {
                Button { isReviewing = true } label: {
                    HStack(spacing: 4) {
                        Text(language.text("확인할 일정 \(board.reviews.count)개", "\(board.reviews.count) to confirm"))
                        Image(systemName: "chevron.right").font(.caption2.weight(.semibold))
                    }
                    .font(.footnote.weight(.semibold)).foregroundStyle(TravelInk.actual)
                    .frame(minHeight: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("travelTodayReviewCount")
                TravelTodayConfirmRow(model: model, tripID: entry.id, review: review, language: language)
            }
            HStack(spacing: 8) {
                if let sheet {
                    let headline = TravelPlanSpend.headline(sheet)
                    let amount = LedgerMoney.text(headline.amount, language: language)
                    Text(headline.isLeftover ? language.text("남은 돈 \(amount)", "\(amount) left") : language.text("쓴 돈 \(amount)", "Spent \(amount)"))
                        .font(.footnote.weight(.medium)).lineLimit(1).minimumScaleFactor(0.8)
                        .foregroundStyle(headline.isLeftover && headline.amount < 0 ? TravelInk.actual : TravelInk.plan)
                }
                Spacer(minLength: 0)
                TravelTodayChip(title: language.text("계획과 실제", "Plan vs actual"), symbol: "chart.bar.xaxis", isFilled: false, action: onReality)
                TravelTodayChip(title: language.text("지출", "Expense"), symbol: "wonsign", isFilled: true, action: onExpense)
            }
        }
        .foregroundStyle(TravelInk.plan)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .accessibilityIdentifier("travelTodayCard")
    }

    private var heading: String {
        guard !entry.isDayTrip, let number = entry.dayNumber else { return language.text("오늘", "Today") }
        return language.text("오늘 · \(number)일차", "Today · Day \(number)")
    }

    @ViewBuilder private func plans(_ board: TravelTodayBoard) -> some View {
        if let current = board.current {
            line(language.text("지금", "Now"), current.title, TravelTodayText.left(board.remainingMinutes, language), isStrong: true)
        }
        if let next = board.next {
            let travel = board.travelMinutes.map { language.text("이동 \($0)분", "\($0) min away") }
            line(language.text("다음", "Next"), "\(TravelTodayText.clock(next.startMinute)) \(next.title)", travel, isStrong: board.current == nil)
        } else if board.current == nil {
            Text(language.text("오늘 일정을 마쳤습니다", "Today's plans are done")).font(.subheadline.weight(.medium))
        }
    }

    private func line(_ label: String, _ title: String, _ detail: String?, isStrong: Bool) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.caption.weight(.bold)).foregroundStyle(TravelInk.land)
                .padding(.horizontal, 7).frame(height: 20)
                .background(isStrong ? TravelInk.plan : TravelInk.plan.opacity(0.55), in: Capsule())
            Text(verbatim: title).font(.subheadline.weight(isStrong ? .semibold : .medium)).lineLimit(1)
            Spacer(minLength: 0)
            if let detail { Text(detail).font(.footnote.weight(.medium)).opacity(0.8).lineLimit(1).layoutPriority(1) }
        }
        .accessibilityElement(children: .combine)
    }
}

/// 카드의 작은 단추.
private struct TravelTodayChip: View {
    let title: String
    let symbol: String
    let isFilled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.footnote.weight(.semibold)).lineLimit(1)
                .foregroundStyle(isFilled ? TravelInk.land : TravelInk.plan)
                .padding(.horizontal, 11).frame(height: 34)
                .background(isFilled ? TravelInk.plan : TravelInk.planTint, in: Capsule())
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 지난 일정 하나를 갔음·건너뜀으로 확정하는 줄. 자동 기록이 맞으면 「갔음」이 미리 골라져 보인다.
struct TravelTodayConfirmRow: View {
    @Bindable var model: AppModel
    let tripID: String
    let review: TravelTodayBoard.Review
    let language: MapHomeLanguage

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: review.stop.title).font(.subheadline.weight(.medium)).lineLimit(1)
                Text(TravelTodayText.clock(review.stop.startMinute) + "–" + TravelTodayText.clock(review.stop.endMinute)
                    + (review.suggestsVisited ? " · " + language.text("머문 기록 있음", "Stay recorded") : ""))
                    .font(.caption).opacity(0.75).lineLimit(1)
            }
            Spacer(minLength: 0)
            ForEach(TravelVisitMark.allCases, id: \.self) { mark in
                let isPicked = mark == .visited && review.suggestsVisited
                Button { TravelTodayText.confirm(mark, model: model, tripID: tripID, itemID: review.stop.id) } label: {
                    Label(mark.title(language), systemImage: mark.symbol)
                        .font(.footnote.weight(.semibold)).lineLimit(1)
                        .foregroundStyle(isPicked ? TravelInk.land : TravelInk.plan)
                        .padding(.horizontal, 10).frame(height: 34)
                        .background(isPicked ? TravelInk.plan : TravelInk.planTint, in: Capsule())
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("travelToday-\(mark.rawValue)")
                .accessibilityAddTraits(isPicked ? .isSelected : [])
            }
        }
        .foregroundStyle(TravelInk.plan)
    }
}

/// 「확인할 일정 N개」: 확정 안 된 지난 일정만 차례로 묻는다. 확정한 것은 아래에서 되돌린다.
struct TravelTodayReviewSheet: View {
    @Bindable var model: AppModel
    let tripID: String
    let blocks: [TravelPlanTableModel.Block]
    let language: MapHomeLanguage

    @Environment(\.dismiss) private var dismiss
    /// 「나중에」로 넘긴 일정. 이 창을 닫으면 다시 묻는다.
    @State private var deferred: Set<String> = []

    var body: some View {
        NavigationStack {
            TimelineView(.everyMinute) { context in
                let board = TravelTodayText.board(model: model, tripID: tripID, blocks: blocks, travelMinutes: [:], now: context.date)
                let waiting = board.reviews.filter { !deferred.contains($0.id) }
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let review = waiting.first {
                            Text(language.text("이 일정, 다녀왔나요?", "Did you go to this one?")).font(.headline)
                            TravelTodayConfirmRow(model: model, tripID: tripID, review: review, language: language)
                                .padding(14)
                                .background(TravelInk.planTint.opacity(0.5), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            HStack {
                                Text(language.text("남은 확인 \(waiting.count)개", "\(waiting.count) left")).font(.footnote).foregroundStyle(.secondary)
                                Spacer()
                                Button(language.text("나중에", "Later")) { deferred.insert(review.id) }.font(.footnote.weight(.semibold))
                            }
                        } else {
                            Label(
                                board.reviews.isEmpty ? language.text("오늘 일정을 모두 확인했어요", "All of today's plans are confirmed")
                                    : language.text("나머지는 나중에 확인해요", "The rest can wait"),
                                systemImage: "checkmark.circle"
                            )
                            .font(.subheadline.weight(.medium))
                        }
                        if !board.done.isEmpty {
                            Divider()
                            Text(language.text("확정한 일정", "Confirmed")).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                            ForEach(board.done) { done in
                                HStack(spacing: 8) {
                                    Image(systemName: done.mark.symbol)
                                    Text(verbatim: done.stop.title).lineLimit(1)
                                    Text(done.mark.title(language)).font(.footnote).foregroundStyle(.secondary)
                                    Spacer(minLength: 0)
                                    Button(language.text("되돌리기", "Undo")) {
                                        TravelTodayText.confirm(nil, model: model, tripID: tripID, itemID: done.stop.id)
                                    }
                                    .font(.footnote.weight(.semibold))
                                    .frame(minHeight: 44)
                                }
                                .font(.subheadline)
                            }
                        }
                    }
                    .padding(20)
                    .foregroundStyle(TravelInk.plan)
                }
            }
            .navigationTitle(language.text("오늘 기록 확인", "Confirm today"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(language.text("닫기", "Close")) { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
        .accessibilityIdentifier("travelTodayReviewSheet")
    }
}

extension TravelVisitMark {
    @MainActor func title(_ language: MapHomeLanguage) -> String {
        switch self {
        case .visited: language.text("갔음", "Went")
        case .skipped: language.text("건너뜀", "Skipped")
        }
    }

    var symbol: String { self == .visited ? "checkmark.circle.fill" : "arrow.uturn.forward.circle" }
}

/// 카드의 글과 자료 모으기.
@MainActor
enum TravelTodayText {
    /// 「35분 남음」「1시간 5분 남음」.
    static func left(_ minutes: Int, _ language: MapHomeLanguage) -> String {
        let hours = minutes / 60, rest = minutes % 60
        if hours == 0 { return language.text("\(minutes)분 남음", "\(minutes) min left") }
        return rest == 0 ? language.text("\(hours)시간 남음", "\(hours) h left") : language.text("\(hours)시간 \(rest)분 남음", "\(hours) h \(rest) min left")
    }

    static func clock(_ minute: Int) -> String { String(format: "%02d:%02d", minute / 60 % 24, minute % 60) }

    /// 지금 자료로 본 오늘 카드. 자동 기록 맞춤은 확정을 물을 일정이 있을 때만 센다.
    static func board(model: AppModel, tripID: String, blocks: [TravelPlanTableModel.Block], travelMinutes: [String: Int], now: Date) -> TravelTodayBoard {
        let parts = Calendar.autoupdatingCurrent.dateComponents([.hour, .minute], from: now)
        let nowMinute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        let items = model.settings.travelTripItems ?? []
        let marks = TravelTodayBoard.marks(items, tripID: tripID)
        let suggested = TravelVisitMatch.suggested(
            ids: TravelTodayBoard.reviewIDs(blocks: blocks, nowMinute: nowMinute, marks: marks), items: items, tripID: tripID,
            stops: model.settings.travelPlanStops, stays: model.snapshot.places, actuals: model.snapshot.actuals, now: now
        )
        return .make(blocks: blocks, nowMinute: nowMinute, marks: marks, suggested: suggested, travelMinutes: travelMinutes)
    }

    /// 확정하거나(`mark`) 되돌린다(nil). 공유 여행은 공유 편집기가 먼저 받는다.
    static func confirm(_ mark: TravelVisitMark?, model: AppModel, tripID: String, itemID: String) {
        TripSharePlanEditor.route(model: model, tripID: tripID, edit: .status(itemID: itemID)) {
            Task { await TripSharePlanEditor.setVisitMark(model: model, tripID: tripID, itemID: itemID, mark: mark) }
        }
    }
}

extension AppModel {
    /// 다시 가져온 일정의 상태에, 이미 적어 둔 확정을 이어 준다.
    func visitStatus(_ item: TripImportItem, _ kept: [String: TravelTripItem]) -> String? {
        TravelVisitMark.stored(TravelVisitMark(stored: kept[item.id]?.status), over: item.status.stored)
    }

    /// 일정과 이어진 핀의 상태 칸에 확정을 적는다(TVZ1116C01). 예약·미정은 지킨다. 같은 값이면 저장하지 않는다.
    func setTripVisitMark(_ mark: TravelVisitMark?, tripID: String, itemID: String) async {
        guard acceptsDataMutation(), !isSharedTrip(tripID) else { return }
        var items = snapshot.settings.travelTripItems ?? []
        var stops = snapshot.settings.travelPlanStops
        guard let current = items.first(where: { $0.tripID == tripID && $0.itemID == itemID }) else { return }
        let next = TravelVisitMark.stored(mark, over: current.status)
        var changed = false
        for index in items.indices where items[index].tripID == tripID && items[index].itemID == itemID && items[index].status != next {
            items[index].status = next
            changed = true
        }
        for index in stops.indices where stops[index].tripID == tripID && stops[index].itemID == itemID && stops[index].status != next {
            stops[index].status = next
            changed = true
        }
        guard changed else { return }
        snapshot.settings.travelTripItems = items
        snapshot.settings.travelPlanStops = stops
        await persist()
    }
}
