import SwiftUI
import TaptionPlanStore

/// 여행 계획표와 장부를 잇는다(TVZ1112A01): 일정 칸에 그 시간에 쓴 돈을 보이고, 재생 시각으로 지출을 넣는다.
enum TravelPlanSpend {
    /// 돈 줄·여행 카드의 앞 금액(대표 결정 2026-11-13): 예산을 정했으면 남은 돈, 안 정했으면 쓴 돈.
    static func headline(_ sheet: LedgerTripSheet) -> (amount: Double, isLeftover: Bool) {
        sheet.budget > 0 ? (sheet.leftover, true) : (sheet.myCost, false)
    }

    /// 그 여행 일정들의 예상 지출 합(원).
    static func plannedTotal(items: [TravelTripItem], tripID: String) -> Double {
        items.reduce(0) { $0 + ($1.tripID == tripID ? $1.plannedSpendKRW ?? 0 : 0) }
    }

    /// 일정별 쓴 돈(원). 지출 시각이 일정 시간 안에 들면 그 일정의 것이고, 겹치면 늦게 시작한 일정의 것이다.
    /// 이체·수입·취소된 결제는 세지 않는다.
    static func byItem(items: [TravelTripItem], tripID: String, entries: [LedgerEntry]) -> [String: Double] {
        let mine = items.filter { $0.tripID == tripID }.sorted { $0.start > $1.start }
        var result: [String: Double] = [:]
        for entry in entries where entry.tripID == tripID && entry.kind == .expense && entry.transfer == nil && entry.countedKRW > 0 {
            guard let item = mine.first(where: { $0.start <= entry.occurredAt && entry.occurredAt < $0.end }) else { continue }
            result[item.itemID, default: 0] += entry.countedKRW
        }
        return result
    }

    /// 그 시각으로 미리 채운 새 지출.
    static func draft(tripID: String, at date: Date) -> LedgerEntry {
        LedgerEntry(occurredAt: date, amount: 0, title: "", tripID: tripID)
    }

    /// 이동 일정의 이름 후보로 먼저 보이는 탈것. 고양이 동작이 이 낱말로 정해진다(`TravelPlayhead.vehicle`).
    static func vehicles(_ language: MapHomeLanguage) -> [String] {
        [("도보", "Walk"), ("지하철", "Subway"), ("버스", "Bus"), ("택시", "Taxi"), ("기차", "Train"), ("비행기", "Flight"), ("배", "Ferry")]
            .map { language.runtimeText($0.0, $0.1) }
    }
}

/// 여행 머리말 아래의 돈 줄: 예산을 정했으면 남은 돈과 쓴 돈, 안 정했으면 쓴 돈만. 장부가 없으면 만들기. 누르면 장부를 연다.
struct TravelMoneyBar: View {
    let sheet: LedgerTripSheet?
    /// 계획표가 올라와 있어 재생 헤드 시각까지만 센 금액인지.
    let isUpTo: Bool
    let language: MapHomeLanguage
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let sheet {
                    let spent = LedgerMoney.text(sheet.myCost, language: language)
                    let spentText = isUpTo ? language.runtimeText("여기까지 \(spent)", "So far \(spent)") : language.runtimeText("쓴 돈 \(spent)", "Spent \(spent)")
                    if TravelPlanSpend.headline(sheet).isLeftover {
                        Label(LedgerMoney.text(sheet.leftover, language: language), systemImage: "wonsign.circle.fill")
                            .foregroundStyle(sheet.leftover < 0 ? TravelInk.actual : TravelInk.plan)
                        Spacer(minLength: 0)
                        Text(spentText).opacity(0.8)
                    } else {
                        Label(spentText, systemImage: "wonsign.circle.fill")
                        Spacer(minLength: 0)
                    }
                } else {
                    Label(language.text("여행 장부 만들기", "Start trip ledger"), systemImage: "wonsign.circle")
                    Spacer(minLength: 0)
                }
            }
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(TravelInk.panel, in: Capsule())
            .overlay { Capsule().stroke(TravelInk.border, lineWidth: 1) }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("travelMoneyBar")
    }
}
