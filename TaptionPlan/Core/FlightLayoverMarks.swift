import Foundation
import TaptionPlanStore

/// 지구본에서 작은 점으로 그릴 환승 공항 일정(FLT1119A01). 비행 일정 가운데 도착 공항에서 곧(36시간 안에) 다음 비행이 같은 공항에서 떠나는 것이다.
/// 번호 붙은 큰 핀은 그대로 목적지에 쓰고, 이런 경유지는 번호·이름 없이 작은 점으로만 보인다.
enum FlightLayoverMarks {
    static let maximumGap: TimeInterval = 36 * 3_600

    /// 환승 공항에 닿는 비행 일정의 번호(`itemID`). `items`는 한 여행의 일정이다.
    static func layoverItemIDs(in items: [TravelTripItem]) -> Set<String> {
        let flights = items.filter { $0.isFlight && $0.destinationCode != nil }.sorted { $0.start < $1.start }
        var out = Set<String>()
        for flight in flights {
            let arrival = flight.end
            if flights.contains(where: { next in
                next.itemID != flight.itemID && next.originCode == flight.destinationCode && next.start >= arrival && next.start.timeIntervalSince(arrival) <= maximumGap
            }) { out.insert(flight.itemID) }
        }
        return out
    }
}
