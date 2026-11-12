import Foundation
import TaptionPlanStore

/// 여행 계획표와 장부를 잇는다(TVZ1112A01): 일정 칸에 그 시간에 쓴 돈을 보이고, 재생 시각으로 지출을 넣는다.
enum TravelPlanSpend {
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
