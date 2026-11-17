import Foundation
import TaptionPlanStore

/// 「조각 맞추기」(AIT1116A01, 가+다): AI가 올린 미정(`tentative`) 일정이 조각이다.
/// 조각을 눌러 끼우면 계획이 되고, 안 끼운 조각은 그대로 후보로 남는다. 저장 형식은 바꾸지 않는다(상태 칸만 쓴다).
struct TravelPuzzlePiece: Identifiable, Equatable {
    let id: String
    let title: String
    let kind: String
    let start: Date
    let end: Date
    let utcOffsetSeconds: Int
    let plannedSpendKRW: Double?
}

enum TravelPuzzle {
    /// 이 여행의 조각(미정 일정)을 시작 시각 순으로.
    static func pieces(items: [TravelTripItem], tripID: String) -> [TravelPuzzlePiece] {
        items
            .filter { $0.tripID == tripID && TripItemStatus(raw: $0.status) == .tentative && TravelVisitMark(stored: $0.status) == nil } // 갔음·건너뜀을 확정한 미정은 조각이 아니다
            .sorted { ($0.start, $0.itemID) < ($1.start, $1.itemID) }
            .map { TravelPuzzlePiece(id: $0.itemID, title: $0.title, kind: $0.kind, start: $0.start, end: $0.end, utcOffsetSeconds: $0.startOffsetSeconds, plannedSpendKRW: $0.plannedSpendKRW) }
    }

    /// 이 조각을 끼우면 시간이 겹치는 확정 일정(계획·예약). 다른 조각(미정)과 겹치는 것은 문제 삼지 않는다.
    static func conflicts(of piece: TravelPuzzlePiece, items: [TravelTripItem], tripID: String) -> [TravelTripItem] {
        items.filter {
            $0.tripID == tripID && $0.itemID != piece.id && TripItemStatus(raw: $0.status) != .tentative
                && $0.start < piece.end && piece.start < $0.end
        }
    }

    /// 새로 올라온 조각 번호(딸깍 효과용). 처음 보는 판(`previous`가 nil)이면 비어 있다.
    static func arrivals(previous: Set<String>?, current: [TravelPuzzlePiece]) -> Set<String> {
        guard let previous else { return [] }
        return Set(current.map(\.id)).subtracting(previous)
    }

    /// 조각이 속한 날(그곳 현지 날짜) 키 `yyyy-MM-dd`.
    static func dayKey(_ piece: TravelPuzzlePiece) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: piece.utcOffsetSeconds) ?? .gmt
        let parts = calendar.dateComponents([.year, .month, .day], from: piece.start)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
